# Audio/Video Sync + High-Speed Shuttle (FF/Reverse) Spec (v1)

## Goals
- Make **audio the master clock** during playback whenever audio is enabled.
- Eliminate echo/repeat, scratchy audio, and decoder churn caused by per-frame SetTarget.
- Keep the UI responsive at all speeds, including reverse and >4×.
- Allow **frame skipping** (both directions). Prefer visually pleasant presentation.
- Keep changes minimal and principle-driven: clear invariants, explicit boundaries, assertions for “must be true”.

## Non-Goals (v1)
- Perfect reverse decode performance for all codecs without frame skipping.
- Seamless click-free speed changes (we accept small discontinuities when reanchoring).
- Int64 rational time/frame math in Lua (we wrap it for future swap if needed).

---

## Terms / Components
- **AOP**: audio output pipeline (device buffer, playhead tracking).
- **SSE**: scrub/stretch engine (time-stretch + pitch correction).
- **audio_playback.lua**: owns audio transport, pump, timekeeping, SSE interactions.
- **playback_controller.lua**: owns UI tick, frame selection, transport UI state.
- **Transport event**: start/stop/pause/seek/speed/direction/quality-mode change.

---

## Core Architecture: Audio-Master Model
### Rule A1 (time authority)
- When audio is active, **audio is the master clock**:
  - Video queries audio for “heard time” and displays the corresponding frame.
  - Video never pushes time into audio during steady-state playback.

### Rule A2 (SetTarget usage)
- `SSE.SET_TARGET(t_us, speed, mode)` is called **only on transport events**.
- It is **never** called from the video tick loop during steady-state playback.

### Data Flow
#### Transport events
`playback_controller` → `audio_playback.start/seek/set_speed/set_mode/stop/pause`
- `audio_playback` performs:
  - clear queued audio (flush)
  - reset SSE
  - set SSE target once for the new transport state

#### Steady-state playback
- **Audio pump** runs based on buffer need:
  - ensure PCM cache is populated around SSE render cursor
  - render only what’s needed to reach target buffered frames
  - write produced frames to AOP
- **Video tick** runs at display cadence:
  - query `audio_playback.get_media_time_us()`
  - compute frame via rational math
  - display (no SetTarget calls)

---

## Timekeeping: “Heard Time” (AOP epoch subtraction)
### Problem
- `AOP.PLAYHEAD_US()` returns elapsed time since some internal origin, not “media time”.
- Relying on FLUSH to reset the playhead counter is brittle.

### Rule T1 (epoch subtraction)
Maintain:
- `media_anchor_us`: media time at the last transport anchor
- `aop_epoch_playhead_us`: AOP playhead reading at the same anchor

Then:
- `elapsed_us = AOP.PLAYHEAD_US() - aop_epoch_playhead_us`
- `media_time_us = media_anchor_us + trunc(elapsed_us * signed_speed)`

### Rule T2 (symmetric truncation)
To avoid bias when reversing:
- if `signed_speed >= 0`: use `floor(delta)`
- else: use `ceil(delta)`

### Rule T3 (clamp to valid media bounds)
We clamp to **frame-derived max**, not container duration metadata:
- `max_media_time_us = (total_frames - 1) * 1_000_000 * fps_den / fps_num`
- clamp: `media_time_us ∈ [0, max_media_time_us]`

---

## Frame Calculation (rational)
### Rule F1
Never use float fps for frame selection.

Frame index from time:
- `frame = floor(t_us * fps_num / (1_000_000 * fps_den))`

Wrap this in one function for future int64 swap:
- `calc_frame_from_time_us(t_us)`

---

## Speed Convention Boundary
### Rule S1
- `playback_controller` stores:
  - `speed_mag` (positive)
  - `direction` (±1)
- `audio_playback` stores:
  - `signed_speed` only

### Rule S2
Compute signed speed exactly once per transport event:
- `signed_speed = direction * speed_mag`
- pass `signed_speed` to audio layer

---

## Audio Pump (buffer-driven, cache-first)
### Targets
- Aim for ~100ms buffered audio (tunable).
- Avoid busy-wait.
- Clamp render chunk size.

### Rule P1 (buffer-driven)
Let:
- `buffered = AOP.BUFFERED_FRAMES()`
- `target_frames = sample_rate * 100ms`
- `frames_needed = max(0, target_frames - buffered)`

### Rule P2 (clamp render)
- `frames_needed = min(frames_needed, MAX_RENDER_FRAMES)` (e.g. 4096)

### Rule P3 (short renders)
SSE may return fewer than requested:
- write only `produced` frames
- if `produced == 0`, back off and retry later

### Rule P4 (adaptive scheduling)
After render attempt:
- if buffer still < target: schedule next pump soon (e.g. 2ms)
- else: schedule later (e.g. 15ms)

### Rule P5 (re-entrancy guard)
Timer callbacks must not overlap pump execution:
- `if pumping then return`
- `pumping=true; pcall(...); pumping=false`

---

## PCM Cache Window (quality-mode dependent)
Quality modes:
- **Q1**: normal time-stretch range (0.25×–4×)
- **Q2**: extreme slow motion (below 0.25×)

Window in µs, biased by direction:

Q1:
- forward: back 200ms, forward 800ms
- reverse: back 800ms, forward 200ms

Q2:
- forward: back 500ms, forward 2000ms
- reverse: back 2000ms, forward 500ms

Cache fill uses SSE render cursor time:
- `render_pos_us = SSE.CURRENT_TIME_US()`
- need `[render_pos_us - back_us, render_pos_us + fwd_us]`

---

## Transport Semantics (start/seek/speed/mode/stop/pause)
### Reanchor helper (single source of truth)
`reanchor(new_media_time_us, new_signed_speed, new_quality_mode)` does:
1. `media_anchor_us = new_media_time_us`
2. `media_time_us = new_media_time_us` (stopped-state fallback)
3. `signed_speed = new_signed_speed`
4. `quality_mode = new_quality_mode`
5. `AOP.FLUSH()` (clear queued audio; not relied on for timekeeping)
6. `aop_epoch_playhead_us = AOP.PLAYHEAD_US()` (capture epoch)
7. `SSE.RESET()`
8. `SSE.SET_TARGET(new_media_time_us, new_signed_speed, new_quality_mode)`

### start()
- `reanchor(media_time_us, signed_speed, quality_mode)`
- prefill pump, start device

### seek(t_us)
- `reanchor(t_us, signed_speed, quality_mode)`

### set_speed(new_signed_speed)
- if not playing: just store speed
- if playing:
  - `current = get_media_time_us()`
  - choose quality mode:
    - abs(speed) < 0.25 → Q2
    - else → Q1
  - `reanchor(current, new_signed_speed, new_mode)`

### stop/pause
- Capture heard time first:
  - `frozen = get_media_time_us()`
- then flush and freeze:
  - `AOP.FLUSH()`
  - `media_anchor_us = frozen`
  - `media_time_us = frozen`
  - `playing=false`
- resume uses `reanchor(frozen, signed_speed, quality_mode)`

---

## Video Tick (audio-follow)
### Rule V1
When audio is active and playing:
1. `t_vid_us = audio_playback.get_media_time_us()`
2. `frame = calc_frame_from_time_us(t_vid_us)`
3. clamp `frame` to `[0, total_frames-1]`
4. display it
5. schedule next tick
6. **never** call `audio_playback.set_media_time()` (remove or make internal-only)

### No-audio fallback (debug-only / best-effort)
If audio isn’t available:
- You may advance based on wall-time dt:
  - `frame += dt_us * signed_speed * fps / 1e6`
But if this isn’t required for production, keep it debug-only.

---

## High-Speed Shuttle Spec (FF + Reverse) with Frame Skipping
### Requirements from you
- Best effort, visually most pleasant.
- Best quality time-stretch + pitch correction up to 4×, then decimate.
- Frame skipping is fine (both directions).
- Prefer on-demand (no heavy background work unless needed).

### Rule H1 (time-based playback)
Maintain a target media time driven by wall time:
- `t_target_us = clamp(t_prev_us + dt_wall_us * signed_speed, 0, max_media_time_us)`

### Rule H2 (target frame)
- `frame_target = calc_frame_from_time_us(t_target_us)`

### Presentation Policy: Hold-last (locked)
When exact target frame is not available quickly:
- **Forward (signed_speed > 0):** present the newest available decoded frame `<= frame_target`
- **Reverse (signed_speed < 0):** present the newest available decoded frame `>= frame_target`

This avoids jitter/pop; it may lag under load but motion stays pleasant.

### Rule H3 (decoder/cache strategy, behavior-only)
Implementation can vary, but behavior must match:
- Maintain a small decoded-frame cache keyed by frame index.
- On each tick:
  - compute `frame_target`
  - request decode around target, direction-biased:
    - forward: prefetch `[frame_target .. frame_target + W]`
    - reverse: prefetch `[frame_target - W .. frame_target]`
  - present using Hold-last rules
- Decoder must not block the UI tick; decode work is bounded per tick.

### Rule H4 (boundary latch)
If `t_target_us` clamps:
- **shuttle mode:** latch at boundary (keep showing boundary frame) and stop moving time until direction changes or seek occurs.
- **normal play mode:** call `stop()` at boundary.

This prevents repeated reanchoring/resets at t=0 or t=max.

---

## Audio Policy at Speed (pitch correction + decimate)
### Rule A-Speed1 (<= 4×)
- Use SSE time-stretch with pitch correction: Q1.
- signed_speed can be negative (reverse) and must be supported by the audio layer’s conventions.

### Rule A-Speed2 (> 4×)
- Decimate audio (no pitch correction). Goal: intelligible-ish or at least non-garbled, but not expensive.
- Transport event on crossing threshold:
  - reanchor into decimate mode
  - flush/reset once

(Exact decimation algorithm can be simple for v1: drop samples/frames with minimal filtering; refine later.)

---

## “If these are signs of bugs, assert” (v1 assertions)
These are invariants where violating them indicates a bug or broken assumption.

### Assert set (keep for now, can downgrade to logs later)
1. **Transport-only SetTarget**
   - Assert: `SSE.SET_TARGET` is never called from the video tick path.
   - Mechanism: debug flag / call-site guard.

2. **Epoch monotonicity**
   - After reanchor, `elapsed_us = PLAYHEAD_US - aop_epoch_playhead_us` should be `>= -small_epsilon` (allow tiny negative due to clock granularity).
   - If large negative: bug in epoch capture ordering or AOP semantics.

3. **Frame-derived max bounds present**
   - Assert `total_frames > 0`, `fps_num > 0`, `fps_den > 0` before computing `max_media_time_us`.

4. **Signed speed correctness**
   - Assert `audio_playback.set_speed(signed_speed)` receives a number and it matches controller’s direction*mag at call time.

5. **Pump re-entrancy**
   - Assert pump guard prevents nested entry (if entered twice, log+return).

6. **SSE render sanity**
   - Assert `produced <= requested`.
   - If produced is wildly negative/huge: bug in binding or engine.

### Not an assert (log only)
- Container duration metadata disagreement: expected; we rely on frame-derived max.

---

## File/Change List (minimal diffs)
1. `src/lua/ui/audio_playback.lua`
   - implement epoch-based heard-time
   - reanchor helper
   - event-driven SetTarget
   - buffer-driven pump (adaptive scheduling, short-render handling, clamp render)
   - PCM cache window scaling
   - remove or internalize `set_media_time` API (video must not call it)

2. `src/lua/ui/playback_controller.lua`
   - store fps as rational (num/den)
   - `calc_frame_from_time_us()`
   - tick uses `audio_playback.get_media_time_us()` (audio-follow)
   - implement shuttle time-based stepping + Hold-last presentation policy hooks
   - boundary latch behavior for reverse-at-0 and forward-at-end

3. `src/scrub_stretch_engine/sse.cpp`
   - remove hacks that existed only to tolerate repeated SetTarget calls
   - keep overlap de-dup if it’s still valid for real seeks

4. `tests/unit/test_sse_core.cpp`
   - update/remove tests that depended on removed hacks
   - add tests for new invariants if available

---

## Verification Checklist
### Unit
- SSE unit tests pass after reverting hacks.
- New timekeeping tests:
  - reanchor sets epoch and anchor
  - get_media_time_us advances correctly for + and − speeds (floor/ceil behavior)

### Manual
1. JKL shuttle (±1×, ±2×, ±4×)
   - no echo/repeat
   - no scratchy audio
   - reduced AAC warnings (if applicable)
2. Seek while playing
   - clean audio after seek (single reanchor)
3. Direction flip (J↔L)
   - no constant reanchoring; boundary latch works
4. >4× (8×, 16×)
   - decimated audio mode engages
   - video remains responsive, frame skipping acceptable
   - Hold-last presentation looks stable (no jitter)

---

## Open knobs (acceptable defaults)
- `target_buffer_ms = 100`
- `MAX_RENDER_FRAMES = 4096`
- Pump schedule: 2ms hungry / 15ms healthy
- Cache windows per Q1/Q2 as defined above
- Prefetch window `W` for video decode: start small (e.g. 8–32 frames) and tune

