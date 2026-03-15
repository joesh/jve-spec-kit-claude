# Research: Fast Rewind Freezes Picture

**Date**: 2026-03-13
**Status**: Diagnosed, fix pending
**File**: `src/editor_media_platform/src/emp_timeline_media_buffer.cpp`

## Symptom

Fast rewind (J×2, dir=-1 speed=2.0) freezes the picture. Reverse 1x briefly works while forward-cached frames last, then freezes.

## Root Cause

The buffer frontier (`video_buffer_end`) only moves forward. Direction is `+1` or `-1`, but `fill_prefetch` and its watermark helpers ignore it — they always add, never subtract. During reverse play the prefetch fills frames the playhead will never visit, delivers nothing, and spins.

### Why the freeze is total

1. `SetPlayhead` resets `video_buffer_end = -1` on direction flip
2. `fill_prefetch` replaces `-1` with `playhead`, starts filling **forward**
3. `set_already_fetched_video` advances frontier via `max()` — can't go backward
4. `pick_video_track` computes `ahead = (playhead - buffer_end)` for reverse = **negative** → "most urgent"
5. `fill_prefetch` re-enters, decodes a frame already in cache (instant no-op), advances frontier forward again
6. Eventually frontier hits `playhead + MAX`, "full" check triggers, returns
7. `pick_video_track` still sees negative ahead → picks track again → loop from step 4

~140K iterations in 4 seconds. No frames delivered. CPU pegged.

## Recommended Abstraction: `PrefetchCursor`

The frontier is a cursor that should know which way it's moving. Encapsulate the direction arithmetic once:

```cpp
class PrefetchCursor {
    int m_dir;  // +1 or -1
public:
    int64_t pos;

    PrefetchCursor(int64_t pos, int direction)
        : m_dir(direction), pos(pos) {
        assert(direction == 1 || direction == -1);
    }

    int64_t ahead_of(int64_t playhead) const {
        return (pos - playhead) * m_dir;
    }

    void advance(int stride) {
        pos += stride * m_dir;
    }

    bool is_further(int64_t new_pos) const {
        return (new_pos - pos) * m_dir > 0;
    }

    void skip_gap(int64_t gap_start, int64_t gap_end) {
        pos = (m_dir > 0) ? gap_end : gap_start - 1;
    }
};
```

Call sites read like plain English:

```cpp
if (cursor.ahead_of(playhead) >= PREFETCH_MAX) return;   // full?
cursor.advance(stride);                                    // step frontier
if (cursor.is_further(new_pos)) watermark = cursor.pos;   // monotonic guard
cursor.skip_gap(seg.start, seg.end);                       // jump past gap
```

No `* direction` at call sites. No branches except `skip_gap`'s inherent two-edge choice.

**All existing direction-aware ternaries should migrate to `PrefetchCursor`** — otherwise we've added a new abstraction without reducing the old one, increasing total complexity. The cursor should become the single way to express direction-relative arithmetic in this file.

## What's Broken (6 sites)

All share the same pattern: bare `+`, `>`, or `>=` that assume forward movement.

| # | Location | Bug | Cursor equivalent |
|---|---|---|---|
| 1 | `fill_prefetch` video "full" check (line ~2358) | `buffer_end >= playhead + MAX` | `cursor.ahead_of(playhead) >= MAX` |
| 2 | `fill_prefetch` video watermark advance (line ~2407) | `buffer_end + stride` | `cursor.advance(stride)` |
| 3 | `set_already_fetched_video` monotonic guard (line ~1246) | `pos > video_buffer_end` | `cursor.is_further(pos)` |
| 4 | `fill_prefetch` audio "full" check (line ~2433) | `buffer_end >= playhead_us + MAX` | `cursor.ahead_of(playhead_us) >= MAX` |
| 5 | `set_already_fetched_audio` monotonic guard | `pos > audio_buffer_end` | `cursor.is_further(pos)` |
| 6 | `fill_prefetch` video gap skip (line ~2382) | `set_already_fetched(seg.end)` | `cursor.skip_gap(seg.start, seg.end)` |

## What's Missing: Speed-Aware Stride

`stride_for_clip` (line ~1220) computes stride from decode cost vs frame period but ignores playback speed:

```cpp
// Current:
int stride = ceil(decode_ms / frame_period_ms) + 1;

// Fix: factor in speed
float speed = m_playhead_speed.load(std::memory_order_relaxed);
float effective_period = frame_period_ms / max(1.0f, abs(speed));
int stride = ceil(decode_ms / effective_period) + 1;
```

At 2x, effective period halves → stride doubles. `m_playhead_speed` is already stored (line ~445) but never read by prefetch.

## Migrate to `PrefetchCursor` (currently correct but using raw ternaries)

These sites work but use `(dir > 0) ? (a-b) : (b-a)` ternaries that should be replaced with `cursor.ahead_of()`:

- `pick_video_track` (line ~2013), `pick_audio_track` (line ~2057) — `ahead` calc
- `is_video_buffer_low` (line ~1164), `is_audio_buffer_low` (line ~1170) — distance calc
- `GetVideoFrame` nearest-frame fallback (line ~582) — directional cache lookup

These are correct but use a separate direction idiom. Migrating them to `PrefetchCursor` eliminates the ternary pattern entirely from the file.

Sites that DON'T migrate (different concerns):
- Audio mix thread — two-edge PCM buffer, not a single frontier cursor
- `SetPlayhead` — resets/probes, not frontier arithmetic
- `video_cache` — direction-agnostic `std::map`

## Verify: `find_segment_at` for Reverse Positions

`fill_prefetch` calls `find_segment_at(ts, buffer_end)` to locate the clip at the frontier. During reverse, the frontier moves to lower frame numbers. Need to confirm `find_segment_at` handles this correctly — if it assumes the query position is at or ahead of some internal cursor, reverse fill will silently return wrong segments.

## Decoder Seeking for Reverse

**Intra-only codecs** (ProRes, DNxHR): `seek(frame-1) + decode` — same cost as forward. No special handling needed.

**Long-GOP codecs** (H.264, H.265): seeking to prior keyframe + decoding N intermediates per target. O(GOP_size) per frame. Real NLEs batch-decode an entire GOP forward, then serve in reverse. Follow-up optimization — the stride system handles slow codecs by skipping frames for now.

## Log Evidence

**TSO**: `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/Terminal Saved Output.txt`

- **Line 9053**: `Play dir=-1 speed=1.0` — reverse works for ~5 frames (92830→92825) on cached forward frames
- **Line 21596**: `Play dir=-1 speed=2.0` — `fill_prefetch ENTER: V1 buf_end=92922 playhead=92825` repeats ~140K times (lines 21590–163000), no DECODE, no deliverFrame
