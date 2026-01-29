# JVE Playback: Shuttle + AV-Sync + Fast Reverse (Spec v1)

Status: **handoff to Claude**  
Date: 2026-01-27  
Scope owner: Joe

## Goals

- **JKL shuttle** with audio as master clock.
- **Boundary latch** in shuttle: hit start/end, *latch* (time stops) until direction changes or seek.
- **Speed ladder**
  - Pitch-corrected audio up to **4x** (best-effort, best-quality).
  - Above **4x to 16x**: audio **decimates** (no pitch correction).
  - Video may **frame-skip** at any speed if needed; pick what looks most pleasant.
- **Reverse video playback that is not “~3 fps forever”**:
  - Reverse at 1x/2x/4x should feel like forward: responsive and continuous.
  - Reverse at 8x/16x can be frame-skippy; still responsive.

## Non-goals

- Long-GOP “hero” reverse decode (GOP-level acceleration, proxy generation, etc.) in v1.
- Perfect A/V phase lock under all CPU starvation; we prefer “keep UI responsive” over trying to be perfect.

---

## Public surface (domain-first)

These are the names we want exposed to JVE (Lua/UI). Internals may use FFmpeg/Qt/etc, but **public names stay domain + intent**.

### Core nouns (keep small)

- **Media**: opened thing (file/stream set). Opaque handle.
- **VideoFrame**: decoded displayable frame (opaque handle or surface ID).
- **AudioClock**: internal; only exposed via `get_play_time_us()`.

> Note: we intentionally do **not** expose “demuxer/decoder/context” nouns.

### Core verbs

- `open(path) -> media`
- `close(media)`
- `probe(media) -> {duration_us, video_fps_num, video_fps_den, total_video_frames, audio_sample_rate, ...}`
- `start(media)` / `stop(media)`
- `seek(media, time_us)`  *(transport event)*
- `set_rate(media, signed_rate)` where `signed_rate < 0` means reverse  *(transport event)*
- `latch(media, time_us)` *(transport event; used by boundary latch)*
- `get_play_time_us(media) -> time_us` *(audio-master time; pure getter when not playing)*
- `get_video_frame(media, frame_index) -> VideoFrame` *(decode/cache under the hood)*

This surface is intentionally “stdio-like”: open/close/read/seek + domain verbs (start/stop/set_rate/latch).

---

## Architectural invariants (PINs)

### Time authority
- **Audio is the master clock.**
- Video **never pushes time** into audio during steady-state.

### Transport events (only places allowed to retarget time)
The following are the only operations allowed to call “retarget audio engine” (SSE RESET/SET_TARGET equivalents):

- `start`
- `seek`
- `set_rate` (includes crossing ≤4x ↔ >4x)
- `latch`
- `unlatch` (direction change away from boundary, or seek while latched)

### Steady-state
- Video tick reads `get_play_time_us()` and converts to frame index for display.
- Audio pump runs **on demand** (buffer driven).

### Latch time must be commanded time
- Latch time is **frame-derived commanded time**, not sampled from the audio output pipeline after a flush.
- While latched, `get_play_time_us()` is a **pure getter** for the latched time.

### Monotonic time inside audio render
- Forward: render time is non-decreasing during steady-state.
- Reverse: render time is non-increasing during steady-state.
- Wrong-direction jumps only allowed immediately after a transport event retarget.

---

## Playback behavior spec

## 1) Modes and boundary behavior

### `transport_mode`
`playback_controller` maintains:
- `state`: `"playing" | "stopped"` (existing coarse gate)
- `transport_mode`: `"none" | "play" | "shuttle"` (new; avoids name collisions)
- `latched`: boolean
- `latched_boundary`: `"start" | "end" | nil`

### Boundary rules
- In **transport_mode == "play"**: reaching boundary **stops** (current behavior).
- In **transport_mode == "shuttle"**: reaching boundary **latches**:
  - frame displayed stays at boundary
  - `get_play_time_us()` remains constant
  - no re-anchoring every tick

### Unlatch rules
Unlatch is a transport event and must cause exactly one retarget (one RESET + SET_TARGET equivalent).

Unlatch triggers:
- Direction change **away from** boundary while latched
- Seek while latched (seek owns the transport event; latch cleared first)
- Stop clears latch

---

## 2) Audio behavior (rates + quality)

### Rate ladder
Let `abs_rate = abs(signed_rate)`:

- `0.25x ≤ abs_rate ≤ 4.0x`: **Pitch-correct** (stretched) audio mode (existing WSOLA/SSE “Q1”)
- `abs_rate < 0.25x`: “extreme slomo” mode (existing SSE “Q2”)
- `4.0x < abs_rate ≤ 16.0x`: **Decimate** audio mode (new SSE “Q3_DECIMATE”)

### Decimate mode constraints
- No new DSP beyond sample dropping / stepping.
- Must work in both directions.
- Must be responsive under shuttle.

### Fail-fast bounds
- If UI sends abs_rate > 16.0: assert/fail fast (bug).

---

## 3) Video behavior (forward + reverse)

Video is expected to be **responsive**. Frame skipping is allowed. The big v1 requirement is: **stop doing expensive work per frame** during reverse.

### Key observation (why reverse is slow today)
If reverse display is ~3 fps at *any* speed, typical causes are:
- seeking the media stream **per frame**
- recreating decoder state **per frame**
- flushing/retargeting decode pipeline **per frame**
- reading many tiny chunks from disk repeatedly (no locality)

The v1 fix is to make reverse display do work in **chunks/windows**, not per frame.

---

# Reverse video rework (Spec v1)

## Goals
- Reverse playback uses **windowed decode**:
  - Seek/flush occurs only when we miss the window (chunk boundary), not for each frame.
  - Within a window, reverse frames are served from an in-memory ring buffer.
- For editor-friendly intraframe codecs (ProRes/DNxHR), reverse can be nearly symmetric to forward.
- For long-GOP later, this same structure still works; it just refills windows by decoding forward from a prior keyframe.

## Non-goals (v1)
- Full long-GOP reverse acceleration with elaborate GOP caches.
- Perfect “every frame” reverse at 16x.

---

## Terminology (domain)
- **Decode session**: persistent state used to decode successive frames without reinitializing.
- **Decode window**: a cached contiguous range of decoded frames around a time.
- **Refill**: operation that seeks once and decodes forward to populate a window.

(These are internal terms. Keep them out of public APIs.)

---

## Video engine interface (what playback_controller needs)

`media_cache` (or equivalent) provides:

- `get_frame(frame_index) -> VideoFrame`
- `prefetch_window_around(frame_index, direction, desired_window_frames)` *(optional; may be no-op in v1)*

Playback controller does **not** talk about demuxers/decoders.

---

## Decode window design

### Data
Per **Media + Video track** maintain:

- `window.start_frame` (inclusive)
- `window.end_frame` (inclusive)
- `window.frames[]` ring buffer of decoded `VideoFrame`s
- `window.valid[]` or `window.count`
- `window.generation` (optional debug)
- `session` (decode session; persists across frames until transport event)

### Window size
- Default: **~0.5–1.0 seconds** worth of frames (e.g., 15–60 frames depending on fps).
- Make it configurable but do not expose a new public API noun.

### Cache policy (simple)
- Keep **one window** per direction (optional):
  - v1 minimum: one window total, refilled as needed.
  - better: keep separate last-forward and last-reverse windows if cheap.
- Eviction: overwrite ring buffer on refill.

---

## Frame selection (when frame skipping is ok)

Given audio-master `time_us` and fps rational:

- Compute ideal `frame = floor(time_us * fps_num / (1e6 * fps_den))`.
- Apply **visual cadence**:
  - At high abs_rate (e.g., ≥ 4x) it’s OK to skip frames.
  - Simple rule: choose `frame_stride = max(1, round(abs_rate))` for shuttle modes.
  - Display `frame` snapped to stride for stability (optional):
    - forward: `frame = frame - (frame % frame_stride)`
    - reverse: same snapping is fine

This avoids trying to show “every frame” at 16x.

---

## Refill algorithm

### When we have the frame in the window
- If `frame_index ∈ [window.start_frame, window.end_frame]` and the entry is decoded:
  - return the cached `VideoFrame` immediately.

### When we miss the window (refill required)
We refill around the target frame. Refill is the only time we:
- seek the underlying media stream
- flush decode session
- decode forward in a batch

**Refill plan:**
1. Choose window `[start, end]` that contains `target_frame` and is biased by direction:
   - reverse: want window ending at target: `end = target_frame`, `start = max(0, end - window_size + 1)`
   - forward: want window starting at target: `start = target_frame`, `end = min(last, start + window_size - 1)`
2. Compute a **seek point** at or before `start`.
   - intraframe: seek point can be `start` directly (cheap).
   - long-GOP later: seek to nearest prior keyframe (implementation detail).
3. Seek once to seek point.
4. Decode forward frames from seek point up through `end`.
5. Store decoded frames into the window buffer keyed by frame index.
6. Return the requested frame.

**Important:** even in reverse playback, refill decodes forward. Reverse display is achieved by serving frames from the window in reverse order.

### Don’t thrash on boundaries
If reverse playback is stepping backward and repeatedly misses because the window is biased wrong:
- ensure reverse window is biased to end at target (as above)
- window size must be large enough that successive reverse frames hit the window most of the time

---

## Transport events and video decode sessions

Transport events (seek, set_rate sign flip, latch/unlatch) may invalidate the current decode session.

Rules:
- On `seek`: invalidate window + session (generation++).
- On `set_rate` direction flip (sign change):
  - keep window if it still contains target (optional)
  - otherwise refill biased for new direction
- On `latch`: no refill, just hold current frame.
- On `unlatch`: resume normal ticking; next frame request can trigger refill as needed.

---

## Performance targets (v1)

For editor-friendly intraframe codecs on a typical modern machine:
- Reverse 1x: > 24 fps display loop (UI-limited)
- Reverse 2x/4x: visually smooth, may skip a little depending on UI tick rate
- Reverse 8x/16x: responsive “shuttle” feel; skipping expected

For long-GOP later:
- Same structure works, but refill cost increases (acceptable for v1 non-goal).

---

# Integrating with the existing AV-sync + shuttle plan

This reverse work plugs into the existing plan as:
- Audio-master time stays exactly as specified.
- Video tick translates time->frame and asks media_cache for that frame.
- media_cache implements the windowed reverse refill so reverse no longer crawls.

---

## Implementation phases (order)

### Phase 0: Audit + simplify (mandatory before new features)
- Remove/avoid silent no-ops:
  - missing requires must crash loudly
  - no pcall “swallow errors” in pump paths
- Ensure current tests run (or add minimal ones that do).

### Phase 1: Boundary latch (as already planned)
- Implement controller latch state + audio_playback.latch(time_us)
- Add `tests/test_boundary_latch.lua`

### Phase 2: >4x audio decimate (as already planned)
- Add SSE Q3_DECIMATE, MAX_SPEED constants, render_decimate
- Add Lua thresholding + reanchor rules
- Add `tests/unit/test_sse_decimate.cpp`
- Add `tests/test_audio_decimate.lua`

### Phase 3: Reverse video rework (this spec)
- Implement windowed decode in `media_cache` (or whatever owns video decode)
- Add tests:
  - `tests/test_reverse_windowed_decode.lua` (Lua integration)
  - Optional C++ unit tests for seekpoint/index mapping if available

---

## Reverse tests (minimum)

### Integration: reverse should not seek per frame
Add instrumentation counters (debug-only):
- `media_cache.debug_seek_count`
- `media_cache.debug_decode_frame_count`

Test scenario:
1. Play reverse at -1x for N ticks requesting sequential frames
2. Assert:
   - seek_count is **small** (≈ 1 per window refill), not ≈ N
   - decoded frames are batched (decode_frame_count grows by window size per refill)

### Behavior: reverse cadence
- At -1x: frames should move backward each tick (or most ticks)
- At -8x/-16x: frames move backward with skips, but no long stalls

---

## Known sharp edges (call out explicitly)

- Frame/time mapping must use **fps rational** consistently:
  - `frame = floor(time_us * fps_num / (1e6 * fps_den))`
  - `time_us = floor(frame * 1e6 * fps_den / fps_num)`
- End boundary time refers to **start of last frame** (`total_frames - 1`).
- Window refill must avoid off-by-one gaps when direction flips.

---

## “Domain naming” cleanup list (for the refactor you want)

Rename public-facing names away from mechanism jargon. Examples:

- “Asset/Reader” → avoid. Prefer:
  - `Media` (opened file)
  - `VideoDecodeSession` (internal only)
  - `AudioDecodeSession` (internal only)

- “AVFormatContext/AVCodecContext” must not appear in Lua names, module names, or public function names.

Mechanism details belong only in comments inside implementation modules, not public API or high-level specs.

---

## Files likely involved (adjust to codebase reality)

- `src/lua/ui/playback_controller.lua`
- `src/lua/ui/audio_playback.lua`
- `src/lua/ui/media_cache.lua`  *(reverse windowing likely lives here)*
- `src/scrub_stretch_engine/sse.h`
- `src/scrub_stretch_engine/sse.cpp`
- tests under `tests/` and `tests/unit/`

---

## Done criteria

- Boundary latch works in shuttle and does not relatch/reanchor every tick.
- Audio decimate mode works 8x/16x both directions.
- Reverse video no longer stuck at ~3 fps:
  - reverse -1x feels comparable to forward responsiveness for intraframe sources
  - reverse -8x/-16x feels responsive (skippy acceptable)
- All new tests pass.

