# JVE Audio Enablement Plan (EMP-Compatible) v1 — Claude Spec

## Goal
Add **audible audio playback** for the Source Viewer while preserving the EMP boundary:
- EMP contains FFmpeg/swresample decoding/conversion “cruft”.
- A new Audio Output Platform (AOP) module owns the OS audio device.
- Lua owns playback policy (what to decode, when to buffer, how to sync).

This plan is compatible with `JVE_EDITOR_MEDIA_PLATFORM_SPEC_v4_1.md` and does not alter its constraints.

## Feature scope (v1)
- Source Viewer audio for a single clip (no timeline mixing).
- Reasonable A/V sync using an audio-master clock (no perfection demanded).
- Worker-thread decode + request coalescing.
- Output: stereo float32 interleaved at device sample rate.
- No effects, no automation, no time-stretch.

## Non-goals (v1)
- Timeline audio mixing (multiple clips)
- Pitch-preserving stretch, elastic audio
- Loudness management, metering
- Multi-device routing
- Proxy audio generation

---

## Module responsibilities

### 1) EMP (extend)
EMP gains audio decode primitives and conversion:
- Demux/decode audio frames via FFmpeg
- Resample/remix to requested PCM format (swresample stays inside EMP `impl/`)
- Seek by editor time (FrameTime) consistently with video
- Provide PCM chunks with stable lifetime and metadata

EMP still does **not** talk to audio devices.

### 2) AOP (new module)
Audio Output Platform owns the device:
- Open/configure device (Qt audio backend recommended initially)
- Ring buffer
- Device callback / write loop
- Playhead/latency reporting
- Underrun detection

No FFmpeg headers/types here.

### 3) Lua Source Viewer playback policy (new or extended module)
Lua:
- picks clip CFR grid (nominal rate influenced by sequence, as in EMP spec)
- drives decode scheduling for audio blocks
- uses AOP playhead as master clock for sync
- coalesces/cancels stale requests during scrubbing

---

## EMP C++ API additions (editor-facing is frame-first)

### New types
#### Audio format descriptor
```
namespace emp {
enum class SampleFormat { F32 }; // v1 only
struct AudioFormat {
  SampleFormat fmt;      // F32
  int32_t sample_rate;   // device rate
  int32_t channels;      // 2 (stereo) in v1
};
}
```

#### PCM chunk
```
namespace emp {
class PcmChunk {
public:
  int32_t sample_rate() const;
  int32_t channels() const;           // interleaved
  SampleFormat format() const;        // F32
  int64_t start_time_us() const;      // media time of first sample (debug/telemetry)
  int64_t frames() const;             // number of sample-frames
  const float* data_f32() const;      // interleaved
};
}
```

Lifetime:
- PcmChunk is refcounted (`std::shared_ptr<PcmChunk>`) like `Frame`.

### AssetInfo additions
- `has_audio`
- `audio_sample_rate` (source)
- `audio_channels` (source)
- `audio_channel_layout` (optional string or enum)
- `audio_duration_us` (if available; else use container duration)

### Reader additions (video-only remains valid)
Frame-first audio API:
- `Result<std::shared_ptr<PcmChunk>> Reader::DecodeAudioRange(FrameTime t0, FrameTime t1, AudioFormat out);`

Semantics:
- t0/t1 are on the selected CFR grid (FrameTime).
- EMP converts to target time window in microseconds, then decodes/resamples enough source samples to cover `[t0, t1)`.
- If the source is VFR, the audio time base is still continuous; treat it as absolute media time derived from FrameTime conversion.
- On EOF: return a shorter chunk (or empty) but not an error unless decode fails.

Pinned output format (v1 default):
- `out = { fmt=F32, sample_rate=device_rate, channels=2 }`
- Downmix to stereo if source has >2 channels (simple matrix or FFmpeg default downmix).

---

## AOP module (new)

### Backend choice (v1)
- Use Qt audio output (`QAudioSink`) if available.
- If Qt audio is not stable in your current setup, swap to CoreAudio later without changing EMP.

### AOP API (C++ surface)
Keep this minimal and extraction-friendly.

```
struct AopConfig {
  int32_t sample_rate;     // requested
  int32_t channels;        // 2
  int32_t target_buffer_ms; // default 100
};

class AudioOutput {
public:
  static std::unique_ptr<AudioOutput> Open(const AopConfig&, AopOpenReport* out_report);
  void Close();

  // Write PCM into ring buffer. Returns frames accepted.
  int64_t WriteF32(const float* interleaved, int64_t frames);

  // How many frames are currently buffered (approx).
  int64_t BufferedFrames() const;

  // Device clock / playhead in microseconds since start (or absolute monotonic).
  int64_t PlayheadTimeUS() const;

  // Latency estimate (buffer + device) in frames.
  int64_t LatencyFrames() const;

  bool HadUnderrun() const; // sticky until cleared
  void ClearUnderrunFlag();
};
```

Pinned defaults (v1):
- `target_buffer_ms = 100`
- block decode size: 20ms chunks

Threading:
- AudioOutput is thread-safe for `WriteF32` from the decode/driver thread, but `Close` must coordinate shutdown.

---

## Lua policy (Source Viewer)

### New Lua module
- `src/lua/media/source_audio_player.lua`

Responsibilities:
- Own AudioOutput handle (via bindings to AOP)
- Own current EMP Reader for audio (same Reader as video is fine)
- Maintain:
  - `generation_id` for cancellation
  - selected CFR grid rate
  - desired buffered-ahead target (100ms)

### Clocking
- Audio device is master.
- At each service tick (Lua timer or worker loop):
  1) `playhead_us = AOP.PlayheadTimeUS()`
  2) `desired_ahead_us = 100_000` (100ms)
  3) If buffered < target, request decode for `[playhead_us + buffered_us, playhead_us + desired_ahead_us]`
     - Convert those times back to FrameTime indices on the chosen CFR grid:
       - `frame = floor(t_us * rate.num / (1_000_000 * rate.den))`
     - Call `EMP.Reader.DecodeAudioRange(FrameTime(frame0), FrameTime(frame1), out_fmt)`
  4) Write returned PCM into AOP ring buffer.

Coalescing:
- If generation_id changes (scrub, stop, new clip), discard decoded chunks.

Scrubbing behavior (v1 minimal):
- When user scrubs, stop audio output and flush buffer.
- On resume play, restart from the new frame index.

---

## Lua↔C++ bindings

### Add `qt_constants.AOP`
Bindings for AudioOutput:
- `AOP.OPEN(sample_rate, channels, target_buffer_ms) -> aop | nil, err`
- `AOP.CLOSE(aop)`
- `AOP.WRITE_F32(aop, float_array_or_buffer, frames) -> frames_written`
- `AOP.BUFFERED_FRAMES(aop) -> frames`
- `AOP.PLAYHEAD_US(aop) -> t_us`
- `AOP.LATENCY_FRAMES(aop) -> frames`
- `AOP.HAD_UNDERRUN(aop) -> bool`
- `AOP.CLEAR_UNDERRUN(aop)`

### EMP Lua bindings additions
Expose audio decode:
- `EMP.READER_DECODE_AUDIO_RANGE(reader, frame0, frame1, rate_num, rate_den, out_sample_rate, out_channels) -> pcm | nil, err`
- `EMP.PCM_INFO(pcm) -> { sample_rate, channels, frames, start_time_us }`
- `EMP.PCM_RELEASE(pcm)`

Optimization binding (recommended):
- `AOP.WRITE_PCM(aop, pcm) -> frames_written`
  - Writes directly from PcmChunk into AOP without marshaling floats through Lua.

---

## Acceptance criteria (v1)
1) In Source Viewer, press play: audio is audible for clips with audio.
2) Scrub: audio stops and resumes cleanly.
3) No crashes/leaks on repeated load/stop/close.
4) EMP boundary holds: FFmpeg/swresample only inside EMP `impl/`.
5) AOP has no FFmpeg deps; EMP has no Qt audio deps.

---

## Notes for v2
- True A/V sync for video presentation using audio clock + latency compensation.
- Timeline mixing (EAE module).
- Better scrubbing audio previews if desired.
