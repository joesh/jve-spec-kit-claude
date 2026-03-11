# Adaptive Stride Playback

## Problem

Slow-decode codecs (qtrle 4K ~136ms/frame, ProRes 4444 SW ~140ms/frame) can't
deliver frames at real-time rate. The prefetcher must decode every Nth frame and
hold each for N display ticks. Audio always plays continuously.

Currently the algorithm is implicit — scattered across PlaybackController
(display-side stride, predictive stride, audio-master, PLL emergency) and TMB
(REFILL adaptive stride, EMA, probe). These two systems fight each other. This
spec replaces them with one explicit algorithm.

## Components

```
CLOCK             audio callback drives wall-clock position. Never drops.
DISPLAY           per tick, per track: look up frame at playhead. Never blocks.
PREFETCH_CACHE    per-track map of timeline positions → decoded media.
PREFETCHER        background worker. Decodes into cache ahead of playhead.
SPEED_DETECT      one-frame decode to measure codec speed. Populates decode_speed_cache.
```

## Decode Speed Cache

```
decode_speed_cache : Dict[media_path → float ms_per_frame]

Write-once per path. Populated by SPEED_DETECT jobs (one-frame decode,
wall-clock timed). Never updated by EMA or prefetcher.

Scanned proactively by SetPlayhead: every tick, scan PROBE_WINDOW ahead
of playhead across all video tracks. Submit SPEED_DETECT for any clip
whose media_path is not yet in decode_speed_cache.

Invariant: by the time the prefetcher reaches a clip, its speed MUST
already be in decode_speed_cache (the PROBE_WINDOW guarantees this).
If the prefetcher encounters an unprobed clip, that's a bug — assert.
```

## Segments

The timeline is a sequence of **segments**: either a clip or a gap.
Every timeline position belongs to exactly one segment.

```
find_segment_at(track, position) → Segment
    // Returns the clip at this position, or a gap segment
    // spanning from the end of the previous clip to the start
    // of the next clip. Never returns null.

Segment:
    type:   CLIP | GAP
    start:  timeline position (inclusive)
    end:    timeline position (exclusive)
    clip:   Clip reference (only if type == CLIP)
```

Gaps are explicit. There is no null-check-means-gap pattern.

## Prefetcher — Parallel Audio/Video Paths

Video and audio prefetchers share the same algorithmic structure (watermark-driven,
segment-aware gap skip, generation-guarded) but are implemented as separate worker
paths. Merging them would require templates/callbacks across 4 fundamental divergences:
unit mismatch (frames vs microseconds), cache structure (map vs vector), stride
(video-only adaptive skip), and EOF handling (hold-last vs silent skip). The shared
structure is ~30 lines across ~430 lines of divergent logic — the abstraction cost
exceeds the duplication cost.

### Key Concept: already_fetched

The **already_fetched** position is distinct from the playhead.

- **playhead**: where the user is watching right now (owned by CLOCK)
- **already_fetched**: how far ahead the prefetcher has decoded (owned by PREFETCHER)

The prefetcher works ahead of the playhead. Two constants define the buffer zone:

- `PREFETCH_MIN` — minimum distance ahead (e.g. 48 frames = ~2s). Below this, wake.
- `PREFETCH_MAX` — target distance ahead (e.g. 96 frames = ~4s). Fill up to this.

```
Timeline ────────────────────────────────────────────────────────────►

  ··········|##########|=====================|···················|··········
            ▲          ▲                     ▲         ▲         ▲
            │          │                     │         │         │
         eviction    PLAYHEAD        already_fetched   │         │
         boundary                              playhead+      playhead+
                                               PREFETCH_MIN   PREFETCH_MAX

  ··  uncached (evicted or not yet decoded)
  ##  cached, about to be consumed by display
  ==  cached, ahead of playhead (the buffer)
```

- Prefetcher sleeps while `already_fetched >= playhead + PREFETCH_MIN`
- Prefetcher wakes when `playhead + PREFETCH_MIN > already_fetched` (buffer running thin)
- Prefetcher fills until `already_fetched >= playhead + PREFETCH_MAX` (buffer full)
- If `already_fetched < playhead` → prefetcher fell behind → `discard_already_played_prefetch()`

### Top Level

```
prefetch_loop(track):
    while not shutdown:
        wait_until( playhead + PREFETCH_MIN > already_fetched(track) )
        discard_already_played_prefetch(track)
        fill_prefetch(track)
```

### discard_already_played_prefetch

If the playhead has passed the already_fetched (prefetcher fell behind —
e.g. after a seek, or if decode was too slow), jump already_fetched forward
to the playhead. Don't waste time decoding frames the display has already passed.

```
discard_already_played_prefetch(track):
    if already_fetched(track) < playhead:
        already_fetched = playhead
```

### fill_prefetch

Decode from already_fetched toward playhead + PREFETCH_MAX.

```
fill_prefetch(track):
    while already_fetched(track) < playhead + PREFETCH_MAX:
        if shutdown or stopped: break
        if generation_changed(track): break
            // Each play/seek increments a generation counter.
            // If a seek happened mid-prefetch, abandon this batch —
            // we're decoding for a position the user already left.

        segment = find_segment_at(track, already_fetched)

        if segment.type == GAP:
            already_fetched = segment.end    // skip to end of gap
            continue

        stride = stride_for_clip(track, segment.clip)
        decode_into_cache(track, segment, already_fetched, stride)
        already_fetched += stride
        // One decode per iteration. For video stride=1, that's 1 frame.
        // Overhead (segment lookup, stride calc) is O(1); the decode
        // itself is 5-140ms and dominates. Same granularity as current TMB.
```

### Leaf: stride_for_clip

```
stride_for_clip(track, clip):
    if track is audio:
        return audio_chunk_frames(AUDIO_REFILL_SIZE, clip)

    // Video: how many frames can we skip?
    ms_per_frame = decode_speed_cache[clip.media_path]
    assert(ms_per_frame exists, "unprobed clip reached prefetcher: %s", clip.media_path)

    // stride = how many display frames fit in one decode.
    // If decode takes 120ms and frame_period is 41.7ms (24fps),
    // stride = ceil(120/41.7) = 3. We decode every 3rd frame.
    stride = ceil(ms_per_frame / frame_period)

    // MAX_STRIDE caps the worst case. stride=8 means ~3fps at 24fps.
    // Beyond that, playback is unwatchable — better to show a slow
    // slideshow than pretend we're playing. Also limits memory: each
    // stride-fill copies the shared_ptr to S-1 cache slots.
    return clamp(stride, 1, MAX_STRIDE)
```

Stride is looked up fresh at each clip. No EMA. No bleed across clips.

### Leaf: decode_into_cache

```
decode_into_cache(track, segment, position, stride):
    reader = acquire_reader(track, segment.clip)

    if track is video:
        source_frame = timeline_to_source(position, segment.clip)
        frame = reader.DecodeAt(source_frame)
        cache_store(track, position, frame)
        // stride fill: copy same frame to positions we're skipping
        for i in 1..stride-1:
            if position + i < segment.end:    // still in same clip
                cache_store(track, position + i, frame)  // shared_ptr

    if track is audio:
        [src_t0, src_t1] = timeline_to_source_range(position, stride, segment.clip)
        chunk = reader.DecodeAudioRangeUS(src_t0, src_t1)
        cache_store(track, position, chunk)

    // No separate watermark — already_fetched IS the watermark,
    // advanced by the caller (already_fetched += stride).
```

## Display

```
get_display_frame(track, playhead):
    frame = cache_lookup(track, playhead)
    // Stride-fill writes to every position (P through P+S-1),
    // so a direct lookup must always hit. If it doesn't, the
    // prefetcher has a bug — assert immediately.
    assert(frame, "prefetch cache miss at %d — prefetcher bug", playhead)

    if playhead + PREFETCH_MIN > already_fetched:
        wake(prefetcher)

    return frame
```

Display never writes already_fetched. Display never decodes.

## Threading

```
Worker pool: N threads (default 2).
  - 1 thread RESERVED for audio (only picks AUDIO_REFILL jobs)
  - N-1 threads pick any job type

Priority (within non-reserved workers):
  SPEED_DETECT > VIDEO_REFILL > READER_WARM
```

Audio can never be starved by a long video decode.

## A/V Sync (PLL)

PLL stays in PlaybackController for fine A/V sync.
Measures drift between video position and audio clock.
Gently nudges video tick rate (3% correction per tick, +/-0.15 frame max).

PLL does NOT:
- Know about stride (stride is prefetcher-side)
- Do emergency skip/hold (removed — prefetcher handles frame dropping)
- Gate on m_frame_stride (deleted)

## Ownership

| State | Owner | Readers |
|-------|-------|---------|
| already_fetched | Prefetcher (sole writer) | Display (read-only, for wake check) |
| Prefetch cache contents | Prefetcher (writes) | Display (reads) |
| Playhead | Clock | Prefetcher, Display |
| Stride | Prefetcher (from decode_speed_cache) | — |
| decode_speed_cache | SPEED_DETECT (write-once) | Prefetcher, Display |

The display never writes already_fetched.
The prefetcher never writes the playhead.

## Constants

```cpp
// Video (distances in frames, added to playhead)
VIDEO_PREFETCH_MAX      = 96         // ~4s @24fps
VIDEO_PREFETCH_MIN      = 48         // ~2s @24fps
MAX_STRIDE              = 8          // worst case ~3fps at 24fps

// Audio (distances in microseconds, added to playhead)
AUDIO_PREFETCH_MAX      = 2'000'000  // 2s
AUDIO_PREFETCH_MIN      =   500'000  // 0.5s
AUDIO_REFILL_SIZE       =   200'000  // 200ms chunk

// Speed detection
PROBE_WINDOW          = 288        // ~12s @24fps
```

## Deletion Map

### PlaybackController — DELETE (~200 lines)

**Members** (playback_controller.h:359-389):
- `m_frame_stride`, `m_next_decode_frame`
- `m_consecutive_slow_decodes`, `m_consecutive_fast_decodes`
- `m_stride_dropped_count`
- `m_stride_pre_engaged`, `m_pending_stride`
- `m_current_clip_end_frame`, `m_current_clip_media_path`
- Constants: `SLOW_DECODE_CONSECUTIVE`, `FAST_DECODE_CONSECUTIVE`,
  `SLOW_DECODE_RATIO`, `MAX_STRIDE`, `STRIDE_LOOKAHEAD`

**Methods** — delete entirely:
- `shouldDecode()` (lines 1398-1408)
- `updateStrideDetection()` (lines 1410-1468)

**Code blocks** — delete:
- Stride reset in Stop() (lines 752-757)
- Stride gate in tick: `shouldDecode()` call + DROPPED path (lines 1306-1314)
- Predictive stride block (lines 1324-1378)
- Gap stride disengage (lines 1688-1692)
- Transition stride apply/disengage (lines 1710-1738)
- PLL emergency skip/hold (lines 1586-1594)
- All stride log messages

**Modify**:
- Audio-master: decouple from stride. Keep stall detection only.
  Remove `m_audio_master_position = true` on stride engage (line 1439).
  Remove `m_frame_stride == 1` gate on audio-master recovery (line 1516).
- `deliverFrame()`: always called, no stride gate.

### TMB — MODIFY

- **EMA** (line 2232-2234): Remove. `m_decode_ms` is write-once per path.
  REFILL writes only if path not already in map.
- **known_stride** (line 2026): Recompute at each clip boundary within a
  REFILL batch (reset when clip_id changes), not once per batch.
- **Segment model**: `find_segment_at()` / `find_segment_at_us()` replace
  `find_clip_at` + `find_next_clip_after` pairs. Gaps are explicit (Segment::GAP
  with bounds), no null-means-gap pattern. VIDEO_REFILL and AUDIO_REFILL remain
  separate worker paths (see Prefetcher section).
- **Dedicated audio worker**: Reserve 1 thread that only picks AUDIO_REFILL.
- **Gap handling**: Use explicit Segment type (CLIP|GAP) instead of null checks.
- **Rename**: probe_cache → decode_speed_cache, DECODE_PROBE → SPEED_DETECT
  throughout TMB header and source.

### TMB — KEEP

- `m_decode_ms` map (write-once, no EMA) — rename to `m_decode_speed_cache`
- SPEED_DETECT job type + handler (renamed from DECODE_PROBE)
- `PROBE_WINDOW` scanning in SetPlayhead
- Stride fill loop (copy frame to S-1 positions)
- `MAX_ADAPTIVE_STRIDE = 8`
- `GetProbeDecodeMs()` API
- `LastBatchMsPerFrame()` in Reader
- Priority picking (SPEED_DETECT > AUDIO > VIDEO)

### TMB — DELETE

- Gap probing fallback (was in TMB KEEP before — now an assert per Joe's comment)

### Files

| File | Changes |
|------|---------|
| `docs/adaptive-stride-playback.md` | Rewrite (this doc) |
| `src/playback_controller.h` | Delete stride members/constants/methods |
| `src/playback_controller.mm` | Delete ~200 lines stride code, simplify tick path |
| `src/editor_media_platform/include/editor_media_platform/emp_timeline_media_buffer.h` | Dedicated audio worker flag, rename probe→speed_detect |
| `src/editor_media_platform/src/emp_timeline_media_buffer.cpp` | Unify prefetcher, remove EMA, remove gap probe fallback, dedicated audio worker, segment model |

## Verification

1. `make -j4` — clean build, 0 warnings, all tests pass
2. Play timeline with fast codec (ProRes LT) — no stride, smooth playback
3. Play timeline with slow codec (qtrle 4K) — stride engages, frames hold, no black
4. Play timeline with mixed clips (fast → slow → fast) — stride resets at boundaries
5. Audio never drops during slow video decode
6. A/V sync stays within PLL tolerance (~1 frame)
