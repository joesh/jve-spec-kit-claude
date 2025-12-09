# Timeline Timebase Migration Plan (Frames + Audio Samples)

## Goals
- Make timeline math frame-native for video (integer frames at sequence fps), eliminating ms rounding error.
- Support sample-accurate audio (integer samples at audio sample rate) alongside frame-locked video.
- Keep ms only at I/O boundaries (ingest/export/display), not in core timeline math or persistence.

## Time Model
- **RationalTime:** `(value, rate)` representation for time points/durations.
- **Video:** video tracks use `timebase_type = video_frames`, `rate = timeline_fps`; store start/duration/in/out/playhead/markers as frame counts.
- **Audio:** audio tracks use `timebase_type = audio_samples`, `rate = audio_sample_rate`; store start/duration/in/out as sample counts; audio trims/nudges can be sample-accurate.
- **Cross-track ops:** normalize via RationalTime, then quantize to the destination track’s unit (frames for video, samples for audio) unless explicitly in an "audio time units" mode.

## Schema & Persistence
- Replace ms columns with unit-bearing fields:
  - Video: `start_frame`, `duration_frames`, `in_frame`, `out_frame`, `playhead_frame`, marker `_frame` fields.
  - Audio: `start_sample`, `duration_samples`, `in_sample`, `out_sample`.
  - Commands/event log: persist native-unit params with explicit `rate` (fps or Hz) to make replay deterministic.
- Migrations allowed to drop old DBs, so schema can be rewritten to frame/sample columns.

## Runtime Changes
- **Time utilities:** extend `frame_utils` (or new `time_utils`) for RationalTime: conversions to/from frames/samples, add/sub/compare, floor/ceil/round to a target rate, and video-locked vs audio-locked quantization helpers.
- **Track metadata:** add `timebase_type` and `rate` on tracks; defaults: video tracks → frames@timeline_fps; audio tracks → samples@project_audio_rate.
- **Timeline state & commands:** store and process positions/durations in native units; remove ms math. Keyboard/mouse deltas derive from active track unit (1 frame on video, 1 sample—or N samples—on audio). Snapping/constraints operate in native units with cross-track conversion when needed.
- **UI:** Ruler/timecode display stays HH:MM:SS:FF for video; audio view can show samples or HH:MM:SS.mmm. Mouse x → RationalTime based on current track’s unit; renders use frame/sample positions.

## Testing
- Update fixtures to frames/samples; add regressions for:
  - Frame alignment (no half-frames) and sample alignment on audio tracks.
  - Mixed-track snapping (audio to video frame boundaries and vice versa with appropriate quantization).
  - Undo/redo preservation of unit-bearing times.
  - Import/export conversions (media duration tc→frames, frames→ms where required by formats).

## Incremental Migration Steps
1) Add RationalTime utilities and track timebase metadata; keep ms adapters for callers.
2) Convert playhead/selection/snapping caches to RationalTime → frames/samples; UI uses conversions at edges.
3) Convert clip model + constraints to native units; provide temporary adapters while command layer transitions.
4) Update commands (Insert/Nudge/Ripple/Roll/Batch) to consume/emit native units; drop ms math once callers moved.
5) Rewrite schema to frame/sample columns; align event log persistence and replay loaders.
6) Update tests/fixtures to frame/sample expectations; add mixed-track and sample-accurate regressions.

## Open Questions / Decisions
- Default audio rate: **48 kHz**. It will be configurable at app, project, and sequence levels (plan UI/settings injection accordingly).
- Video remains frame-locked; no sub-frame video trims. Audio can operate at sample resolution; consider an explicit “audio time units” toggle only for audio editing modes.
- Any interchange formats requiring ms (keep adapters) beyond tc/frame-based (EDL/AAF/OTIO)?
