# JVE Scrub Stretch Engine (SSE) v1 — Pitch-Preserving Jog/Shuttle (Both Directions)

## Goal
Provide **clear, pitch-preserving audio playback** over a wide range of shuttle speeds, including **slow motion both directions**, for pro-editor-style consonant hunting.

SSE sits between EMP (decode/resample) and AOP (audio device):
- EMP: decode + resample/downmix to device rate (float32 stereo)
- SSE: time-stretch/pitch-preserve + bidirectional rate control + artifact control
- AOP: stable device output + ring buffer + playhead clock

SSE is a **separate module** (DSP “cruft”), intentionally separable from EMP and AOP.

---

## Target speed range (pinned)
- Required “good” range: **|speed| ∈ [0.25×, 4.0×]** (both signs)
- Stretch-to-impressive goal: **down to 0.10×** (both signs), best-effort with higher CPU/latency and more tuning sensitivity.

Definitions:
- `speed` is media-seconds per output-second (negative = reverse).
- Pitch must remain constant (no varispeed pitch shift).

---

## Algorithm choice (pinned for v1)
Use a **time-domain, transient-friendly** stretcher suitable for reverse:
- WSOLA/OLA-family with correlation-based alignment, enhanced transient handling.

Rationale (pinned):
- Consonant intelligibility is the primary criterion.
- Reverse support must be first-class (continuous, not “preview bursts”).
- Phase-vocoder artifacts (phasiness/smear) are disfavored for consonant hunting at 0.25× and below.

---

## Latency/quality operating modes (pinned)
SSE exposes a quality mode that trades latency for intelligibility at extreme slomo:

### Mode Q1 (default, “editor”) — required
- Meets the “good” range (0.25×..4×).
- Target end-to-end added latency: **≤ 60 ms**.
- Stable under rapid speed ramps and direction flips.

### Mode Q2 (extreme slomo) — optional but planned in v1 API
- Enables best-effort down to **0.10×** with improved intelligibility.
- Allowed added latency: **≤ 150 ms**.
- Uses larger analysis windows / lookahead.

The UI/transport can pick Q1 always and auto-switch to Q2 when |speed| < 0.25×.

---

## Module API (C++)

### Configuration
```
struct SseConfig {
  int32_t sample_rate;     // device rate
  int32_t channels;        // 2
  int32_t block_frames;    // output block size (default 512 @ 48k)
  int32_t lookahead_ms_q1; // default 60
  int32_t lookahead_ms_q2; // default 150
  float   min_speed_q1;    // 0.25
  float   min_speed_q2;    // 0.10
  float   max_speed;       // 4.0
  int32_t xfade_ms;        // direction-change crossfade (default 15)
};
```

### Control surface
SSE is driven by a continuously changing target position and speed.

```
class ScrubStretchEngine {
public:
  static std::unique_ptr<ScrubStretchEngine> Create(const SseConfig&);

  // Reset internal state (e.g., on clip change).
  void Reset();

  // Set transport parameters. t_us is media time (can be derived from FrameTime).
  void SetTarget(int64_t t_us, float speed, int quality_mode /*Q1/Q2*/);

  // Provide more source PCM into SSE's source cache (decoded by EMP).
  // start_time_us anchors the first sample in media time.
  void PushSourcePcm(const float* interleaved, int64_t frames, int64_t start_time_us);

  // Produce one output block (interleaved float32 stereo) for the device.
  // Returns frames produced (==block_frames unless starved).
  int64_t Render(float* out_interleaved, int64_t out_frames);

  // Starvation and diagnostics
  bool Starved() const;
  void ClearStarvedFlag();
};
```

Notes:
- `t_us` is internal to SSE; editor clients should feed it by converting from FrameTime using the same rational conversion rule already pinned in EMP.
- SSE requires a continuous cache of source PCM around the moving target.

---

## Direction changes (pinned behavior)
- When speed sign flips, SSE performs a **15 ms crossfade** between previous-direction output and new-direction output while resetting alignment state.
- No click/pops permitted.

---

## Source PCM supply contract (EMP ↔ SSE)
EMP produces PCM at device rate and stereo:
- format: float32 interleaved stereo
- sample_rate: device rate

EMP call pattern (suggested):
- Maintain a rolling cache window around the current target time:
  - Q1: **± 0.8 s**
  - Q2: **± 2.0 s**
- On starvation risk, prioritize fetching in the direction of travel.

SSE does not decode. It only consumes PCM with media-time anchors.

---

## Scheduling (Lua policy + worker threads)
Pinned approach:
- AOP device is master clock.
- Lua computes target `(t_us, speed)` from shuttle input and playhead.
- Worker thread maintains the EMP PCM cache window and calls `PushSourcePcm`.
- Audio render thread (or AOP callback thread) calls `Render()` and writes to AOP.

Coalescing/cancellation:
- Clip changes or hard jumps increment generation IDs and call `Reset()`.

---

## Acceptance criteria (v1)
1) Pitch-preserving, intelligible audio while shuttling **forward and reverse** at:
   - 0.25×, 0.5×, 1×, 2×, 4× (both signs)
2) Best-effort intelligible at **0.10×** in Q2 mode (both signs).
3) No clicks on speed ramps or direction flips.
4) No underruns in steady-state with 100 ms AOP target buffer.
5) SSE stays separate: no FFmpeg deps, no device deps.

---

## Implementation notes (not binding)
- Use correlation search around predicted alignment; bias for transient preservation.
- Consider separate transient detector to reduce smear at 0.10×.
- Maintain monotonic media-time mapping even in reverse (decreasing).
