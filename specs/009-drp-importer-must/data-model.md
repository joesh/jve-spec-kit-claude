# Data Model: File Original TC for Override-Aware Relink & Decode

**Feature**: 009-drp-importer-must | **Date**: 2026-04-11

## Entity Changes

### Media (existing entity — `media` table)

**No schema change.** New fields live in the existing `metadata` JSON blob column.

#### New metadata JSON keys

| Key | Type | Units | Present When | Source |
|-----|------|-------|-------------|--------|
| `file_original_timecode` | integer | video frames at `start_tc_rate` | Override exists: value differs from `start_tc_value` | `BtAudioInfo.TracksBA.StartTime` × `start_tc_rate` |
| `file_original_timecode_audio` | integer | audio samples at `start_tc_audio_rate` | Override exists: value differs from `start_tc_audio_samples` | `BtAudioInfo.TracksBA.StartTime` × `start_tc_audio_rate` |

#### Existing metadata JSON keys (unchanged)

| Key | Type | Units | Description |
|-----|------|-------|-------------|
| `start_tc_value` | integer | video frames at `start_tc_rate` | The master clip's displayed TC — override if present, else file container TC |
| `start_tc_rate` | integer | fps | Frame rate for video TC |
| `start_tc_audio_samples` | integer | samples at `start_tc_audio_rate` | Audio TC origin |
| `start_tc_audio_rate` | integer | Hz | Sample rate for audio TC |

#### Invariants

- When `file_original_timecode` is absent (nil in Lua), consumers MUST treat it as equal to `start_tc_value`.
- When `file_original_timecode` is present, it MUST differ from `start_tc_value` (don't store a redundant copy).
- `file_original_timecode` is always derived from `BtAudioInfo.TracksBA.StartTime` (the file's actual container TC), never from `BtVideoInfo.Time.Timecode` (the override).

#### Consumer semantics

| Consumer | Reads | Behavior when `file_original_timecode` present |
|----------|-------|-------------------------------------------------|
| Display (source viewer, inspector, TC ruler) | `start_tc_value` | No change — already shows override |
| Source-range origin (clip.source_in) | `start_tc_value` | No change — source_in in override space |
| Playback decoder (EMP) | `start_tc_value` via override setter | Calls `set_tc_origin_override(start_tc_value, start_tc_audio_samples)` so probed container TC is replaced |
| Relinker TC matching | Both `start_tc_value` AND `file_original_timecode` | Accepts candidate if probed TC matches either |

### ClipInfo (EMP C++ struct — `emp_timeline_media_buffer.h`)

**No change.** The TC override is per-media-path, not per-clip. Threaded via a separate TMB map, not ClipInfo fields.

### MediaFileInfo (EMP C++ struct — `emp_media_file.h`)

**No new fields.** The override mutates the existing `first_frame_tc` and `first_sample_tc` fields via the setter. No additional state needed beyond a decode-started guard.

### MediaFile (EMP C++ class — `emp_media_file.h`)

**One new method, one new internal flag:**

| Addition | Type | Description |
|----------|------|-------------|
| `set_tc_origin_override(int64_t, int64_t)` | public method | Overrides `m_info.first_frame_tc` and `m_info.first_sample_tc`. Asserts if `m_decode_started` is true. |
| `m_decode_started` | private bool | Set to true on first decode. Used by setter assertion only. |

### TimelineMediaBuffer (EMP C++ class)

**One new data member, one new Lua binding:**

| Addition | Type | Description |
|----------|------|-------------|
| `m_tc_overrides` | `std::unordered_map<std::string, TcOverride>` | Path → override map. Applied in `acquire_reader` after `MediaFile::Open`. |
| `TMB_SET_TC_OVERRIDES(tmb, table)` | Lua binding | Sets the override map. Called once per playback session. |

Where `TcOverride`:
```
struct TcOverride {
    int64_t first_frame_tc;
    int64_t first_sample_tc;
};
```

## State Transitions

```
Media row lifecycle:
  [DRP Import] → metadata populated with start_tc_value + file_original_timecode
                  (if override present; file_original_timecode omitted otherwise)
  [Relink]     → file_path updated; metadata unchanged; no source_in remap
  [Playback]   → EMP reads file_original_timecode presence → calls setter → decode correct
  [Re-import]  → metadata fully replaced from fresh DRP parse
```

## Example: VFX clip with Set Timecode override

```
DRP master clip:
  BtVideoInfo.Time.Timecode = 13:16:12:21  (override TC)
  BtAudioInfo.TracksBA.StartTime = 455.32s  (= 00:07:35:08 at 25fps)

Stored on media row (metadata JSON):
  start_tc_value = 1194321         (13:16:12:21 at 25fps)
  start_tc_rate = 25
  file_original_timecode = 11383   (00:07:35:08 at 25fps)
  start_tc_audio_samples = ...     (13:16:12:21 equivalent at 48kHz)
  file_original_timecode_audio = 21855360  (455.32 × 48000)

Timeline clip:
  source_in = 1194321 + N          (override-space absolute TC)

Relink candidate probed container TC = 00:07:35:08:
  → Matches file_original_timecode (11383) ✓
  → Accepted, no source_in remap

Playback:
  TMB_SET_TC_OVERRIDES({path = {video=1194321, audio=...}})
  → acquire_reader opens file → setter called with start_tc_value
  → file_frame = source_in - first_frame_tc = (1194321+N) - 1194321 = N  ✓
```
