# DRP Binary Blob Fields Reference

Binary blob fields found in DaVinci Resolve Project (.drp) XML files.

## 1. `FieldsBlob` on `SM_Project` (project.xml)

Project-level settings.

### `SequenceTabsData`
Stores which timelines are open in tabs.

**Format:**
- Active UUID (the currently-selected tab)
- 3-byte big-endian integer: tab count
- For each tab: `0x48` length byte + 36-character UUID encoded as UTF-16 Big Endian

---

## 2. `FieldsBlob` on `Sm2Sequence`

Found in `MpFolder.xml` via `Sm2MpTimelineClip` -> `TimelineSharedHandle` -> `Sm2Timeline` -> `Sequence`.

Per-sequence metadata including:
- Embedded JPEG thumbnail data
- `UniqueId` -- sequence UUID
- `ImgWidth`, `ImgHeight` -- thumbnail dimensions
- Other metadata TBD

---

## 3. `UIElementsState` on `Sm2Sequence`

Timeline viewport and UI state. TLV (Type-Length-Value) encoded.

### Container Format

| Offset | Size | Description |
|--------|------|-------------|
| 0 | 4 bytes | Version (observed: 9) |
| 4 | 4 bytes | Entry count |

### Per-Entry Format

| Field | Size | Description |
|-------|------|-------------|
| Name length | 4 bytes | UTF-16 BE string length in bytes |
| Name | N bytes | Key name, UTF-16 Big Endian |
| Type tag | 4 bytes | Value type (see table below) |
| Padding | 1 byte | 0x00 for scalar types; array format TBD |
| Value | varies | Depends on type tag |

### Type Tags

| Tag | Type | Value Size | Description |
|-----|------|------------|-------------|
| 0x01 | bool | 1 byte | Boolean value |
| 0x02 | int32 | 4 bytes | 32-bit signed integer, big-endian |
| 0x03 | pair | 8 bytes | Two 32-bit unsigned integers |
| 0x0C | int32[] | 4 + N*4 bytes | 4-byte count followed by N int32 values |
| 0x26 | double | 8 bytes | 64-bit IEEE 754 double, big-endian |

### Known Keys

Observed across 124 timelines in the anamnesis project.

| Key | Type | Description | Example Values |
|-----|------|-------------|----------------|
| `DUI_SUBTITLE_VIEW_VERT_LAYOUT_RATIO` | double | Subtitle panel vertical split ratio | -0.1 |
| `UI_SUBTITLE_CLIP_HEIGHT` | int32 | Subtitle clip height in pixels | 84 |
| `UI_SUBTITLE_ADJ_TRACK_HEIGHTS` | int32[] | Per-subtitle-track height adjustments | [] |
| `UI_SEQUENCE_ZOOM_PRESET` | int32 | Zoom preset index (2 = custom) | 2 |
| `UI_SEQUENCE_VIDEO_VIEW_Y_POS` | int32 | Vertical scroll position of video tracks | 0-239 |
| `UI_SEQUENCE_VERTICAL_LAYOUT_RATIO` | double | Video/audio panel split ratio | ~0.34 |
| `UI_SEQUENCE_USER_ADJUSTED_VIDEO_TRACK_HEIGHTS` | int32[] | Per-video-track height overrides | [28, ...] |
| `UI_SEQUENCE_USER_ADJUSTED_AUDIO_TRACK_HEIGHTS` | int32[] | Per-audio-track height overrides | [0, -9, ...] |
| `UI_SEQUENCE_SUBTITLE_VIEW_Y_POS` | int32 | Vertical scroll of subtitle panel | 0 |
| `UI_SEQUENCE_SCALE` | double | **Timeline zoom level** (key for viewport restoration) | 0.01-12.7 |
| `UI_SEQUENCE_PLAYHEADS` | int32[] | Playhead positions array | [1, 0, 0, ...] |
| `UI_SEQUENCE_MARK_OUT` | int32 | Mark out position (0x00800000 = unset) | |
| `UI_SEQUENCE_MARK_IN` | int32 | Mark in position (0x00800000 = unset) | |
| `UI_SEQUENCE_FLAGS_PINS_VISIBLE` | bool | Whether flag/pin markers are shown | true/false |
| `UI_SEQUENCE_CLIP_HEIGHT` | int32 | Default clip height | 84 |
| `UI_SEQUENCE_CLIP_APPEARANCE` | pair | Clip display mode | (0, 2) |
| `UI_SEQUENCE_AUDIO_WF_VIEW_OPTION` | int32 | Audio waveform display mode | 3 |
| `UI_SEQUENCE_AUDIO_VIEW_Y_POS` | int32 | Audio tracks vertical scroll | 0 |
| `UI_SEQUENCE_AUDIO_MARK_OUT` | int32 | Audio mark out (0x00800000 = unset) | |
| `UI_SEQUENCE_AUDIO_MARK_IN` | int32 | Audio mark in (0x00800000 = unset) | |
| `UI_SEQUENCE_AUDIO_CLIP_HEIGHT` | int32 | Audio clip height | 60 |
| `UI_SEQUENCE_ACTIVE_PLAYHEAD_ID` | int32 | Which playhead is active | 0 |

---

## 4. `CurPlayheadPosition` on `Sm2MpTimelineClip`

Plain XML integer element (not a blob).

Playhead position in frames, **relative to the timeline's start timecode**.

Example: timeline starts at 00:59:50:00, playhead at 00:59:54:21 at 25fps -> `CurPlayheadPosition = 121`.

---

## 5. `FieldsBlob` on `Sm2TiVideoClip` / `Sm2TiAudioClip`

Per-clip metadata. Binary TLV structure (partially decoded).

Known fields:
- Speed/retime data
- Various clip-level settings

---

## 6. `EffectFiltersBA` on `Sm2TiVideoClip` / `Sm2TiAudioClip`

Effect and filter data per clip.

Known contents:
- Volume level (audio clips): embedded as a dB value in the binary data
- Other effects TBD

---

## 7. `MediaExtents` on `Sm2Sequence`

Two little-endian doubles: `[start_tc_seconds, end_tc_seconds]`.

`start_tc_seconds` is the timeline's starting timecode in seconds since midnight.

Example: `3590.0` = 00:59:50:00.

---

## 8. `MediaFrameRate` on `Sm2TiVideoClip`

16 bytes total:
- 8 bytes: big-endian double (frame rate as float)
- 8 bytes: purpose unknown

Some values are hex-encoded speed data that can be garbage (rejected if < 5%).

---

## 9. `MediaTimemapBA` on clips

Speed/retime mapping data.

Format: version byte + speed value encoded as hex double.

---

## 10. `TracksBA` on `Sm2Sequence`

Track configuration data (partially decoded).

---

## Viewport Restoration from DRP

To restore the viewport that Resolve was showing:

1. Extract `UI_SEQUENCE_SCALE` from `UIElementsState` -> zoom level
2. Extract `CurPlayheadPosition` from `Sm2MpTimelineClip` -> playhead (relative to start_tc)
3. Extract `start_tc_seconds` from `MediaExtents` -> timeline start timecode
4. Compute: `playhead_absolute = start_tc_frame + CurPlayheadPosition`
5. Compute: `viewport_duration = panel_width_frames / scale` (approximate; exact mapping depends on Resolve's internal scale factor)
6. Center viewport around playhead
