# DaVinci Resolve .drp Format Specification

## Overview

A `.drp` file is a ZIP archive containing XML files that describe a DaVinci Resolve project. This document describes the format structure and how JVE maps DRP elements to its internal data model.

## Archive Structure

```
project.drp (ZIP archive)
├── project.xml              # Project metadata, settings, user info
├── Gallery.xml              # Gallery/stills (not imported)
├── MediaPool/
│   └── Master/
│       ├── MpFolder.xml     # Root bin contents + timeline references
│       ├── 001_Folder/
│       │   └── MpFolder.xml # Nested bin contents
│       └── ...
└── SeqContainer/
    ├── {uuid1}.xml          # Timeline sequence data (tracks, clips)
    ├── {uuid2}.xml
    └── ...
```

## Key XML Elements

### Timelines (MediaPool/\*\*/MpFolder.xml)

Timelines are referenced in MpFolder.xml via `<Sm2Timeline>` elements:

```xml
<Sm2Timeline DbId="...">
  <Name>My Timeline</Name>
  <Sequence>
    <Sm2Sequence DbId="abc-123-...">
      <FrameRate>00000000000038400000000000000000</FrameRate>  <!-- 24.0 fps -->
      <Resolution>00000000000007800000000000000438</Resolution>  <!-- 1920×1080 -->
    </Sm2Sequence>
  </Sequence>
</Sm2Timeline>
```

**Key fields:**
- `DbId` - Unique identifier for the timeline object
- `Name` - Display name shown in Resolve's UI
- `Sequence/Sm2Sequence@DbId` - Reference to sequence data in SeqContainer/
- `Sequence/Sm2Sequence/FrameRate` - Timeline fps (hex-encoded IEEE 754 double)
- `Sequence/Sm2Sequence/Resolution` - Timeline resolution (hex-encoded width/height)

### Sequences (SeqContainer/\*.xml)

Each timeline has a corresponding sequence file:

```xml
<Sm2SequenceContainer DbId="...">
  <FrameRate>24</FrameRate>
  <Tracks>
    <Sm2TiTrack>
      <Type>0</Type>           <!-- 0=Video, 1=Audio -->
      <Sequence>abc-123-...</Sequence>
      <Items>
        <Element>
          <Sm2TiVideoClip>...</Sm2TiVideoClip>
        </Element>
      </Items>
    </Sm2TiTrack>
  </Tracks>
</Sm2SequenceContainer>
```

### Tracks

```xml
<Sm2TiTrack DbId="...">
  <Type>0</Type>              <!-- 0=Video, 1=Audio -->
  <Sequence>abc-123-...</Sequence>
  <Items>
    <Element>
      <Sm2TiVideoClip>...</Sm2TiVideoClip>
      <!-- or -->
      <Sm2TiAudioClip>...</Sm2TiAudioClip>
    </Element>
  </Items>
</Sm2TiTrack>
```

**Type values:**
- `0` = VIDEO track
- `1` = AUDIO track

### Video Clips

```xml
<Sm2TiVideoClip DbId="...">
  <Name>Clip Name</Name>
  <Start>86400</Start>           <!-- Timeline position (frames) -->
  <Duration>1440</Duration>      <!-- Clip length (frames) -->
  <MediaStartTime>0</MediaStartTime>  <!-- Source position (frames) -->
  <MediaFilePath>/path/to/file.mov</MediaFilePath>
  <MediaRef>uuid-of-media</MediaRef>
  <WasDisbanded>false</WasDisbanded>  <!-- true = disabled -->
</Sm2TiVideoClip>
```

### Audio Clips

```xml
<Sm2TiAudioClip DbId="...">
  <Name>Audio Clip</Name>
  <Start>86400</Start>           <!-- Timeline position (frames) -->
  <Duration>73794</Duration>     <!-- Clip length (frames) -->
  <MediaStartTime>45845</MediaStartTime>  <!-- Source position (SAMPLES) -->
  <MediaFilePath>/path/to/file.wav</MediaFilePath>
  <MediaRef>uuid-of-media</MediaRef>
  <WasDisbanded>false</WasDisbanded>
</Sm2TiAudioClip>
```

## Unit Systems

### Timeline Coordinates

| Field | Video Clips | Audio Clips | Notes |
|-------|-------------|-------------|-------|
| `Start` | Frames | Frames | Timeline position, same unit for both |
| `Duration` | Frames | Frames | Clip length on timeline |
| `MediaStartTime` | Frames | **Samples** | Position in source media |

**Critical insight:** `Start` and `Duration` are ALWAYS in timeline frames for both video and audio. Only `MediaStartTime` differs: frames for video, samples (at 48kHz) for audio.

**Evidence:** Audio clips are contiguous: `Start[n+1] = Start[n] + Duration[n]`

### Timecode Convention

DRP uses midnight-referenced timecode:
- `Start=0` = 00:00:00:00
- `Start=86400` = 01:00:00:00 at 24fps (86400 = 24 × 60 × 60)

Most professional projects start at 01:00:00:00 TC.

## Mapping to JVE

### Timeline → Sequence

| DRP Field | JVE Field | Notes |
|-----------|-----------|-------|
| `Sm2Timeline/Name` | `sequences.name` | Display name |
| `Sm2Sequence/FrameRate` | `sequences.fps_numerator/fps_denominator` | From hex metadata (fallback: 1-hour TC inference) |
| - | `sequences.width/height` | Defaults to 1920×1080 |
| - | `sequences.audio_rate` | Always 48000 |

### Track Mapping

| DRP Field | JVE Field | Notes |
|-----------|-----------|-------|
| `Type=0` | `tracks.track_type='VIDEO'` | |
| `Type=1` | `tracks.track_type='AUDIO'` | |
| Track order | `tracks.track_index` | 1-based, per type |

### Clip Mapping

| DRP Field | JVE Field | Conversion |
|-----------|-----------|------------|
| `Start` | `clips.timeline_start_frame` | Direct (frames) |
| `Duration` | `clips.duration_frames` | Direct (frames) |
| `MediaStartTime` | `clips.source_in_frame` | Video: direct; Audio: samples |
| - | `clips.source_out_frame` | `source_in + source_duration` |
| `MediaFilePath` | `clips.media_id` → `media.file_path` | Via media table |
| `WasDisbanded=true` | `clips.enabled=0` | Inverted |
| - | `clips.fps_numerator` | Video: timeline fps; Audio: 48000 |
| - | `clips.fps_denominator` | Video: 1; Audio: 1 |

### Source Duration Calculation

For **video clips**:
```lua
source_duration = duration_frames  -- same units
source_out = source_in + source_duration
```

For **audio clips**:
```lua
-- Duration is in frames, source coords are in samples
source_duration_samples = duration_frames * 48000 / timeline_fps
source_out = source_in + source_duration_samples
```

### Media Pool → Bins

| DRP Element | JVE | Notes |
|-------------|-----|-------|
| `MpFolder` | `tags` (kind='bin') | Hierarchical bins |
| Folder nesting | `tags.parent_id` | Parent-child relationships |
| `Sm2Timeline` in folder | - | Timelines placed in bins |

## Frame Rate Detection

### Primary: Hex-Encoded FPS in Sm2Sequence

DRP stores frame rate in `<FrameRate>` elements inside `<Sm2Sequence>` as 128-bit hex strings. Format: two big-endian IEEE 754 doubles (first is fps, second is usually 0).

**Example values:**
| Hex String | FPS Value |
|------------|-----------|
| `00000000000038400000000000000000` | 24.0 |
| `00000000000039400000000000000000` | 25.0 |
| `0000000000003e400000000000000000` | 30.0 |
| `00000000000049400000000000000000` | 50.0 |
| `0000000000004e400000000000000000` | 60.0 |

**Decoding algorithm:**
```lua
local function decode_hex_double(hex_str)
    if not hex_str or #hex_str < 16 then return nil end
    -- Take first 16 chars (first double), decode big-endian IEEE 754
    local bytes = {}
    for i = 1, 16, 2 do
        bytes[#bytes + 1] = tonumber(hex_str:sub(i, i+1), 16)
    end
    -- Use string.pack/unpack (Lua 5.3+) or bit manipulation
    return decode_ieee754_be(bytes)
end
```

### Fallback: 1-Hour Timecode Inference

When `<FrameRate>` is unavailable or empty, infer from earliest clip's Start position using the 1-hour timecode convention:

| Start Frame | Frame Rate | Notes |
|-------------|------------|-------|
| ~86,314 | 23.976 fps | NTSC film (24000/1001) |
| 86,400 | 24 fps | True film |
| 90,000 | 25 fps | PAL |
| ~107,892 | 29.97 fps | NTSC video (30000/1001) |
| 108,000 | 30 fps | |
| 180,000 | 50 fps | PAL high frame rate |
| ~215,784 | 59.94 fps | NTSC high frame rate |
| 216,000 | 60 fps | |

**Inference algorithm** (with 1% tolerance):
```lua
for _, m in ipairs(markers) do
    if math.abs(min_start - m[1]) / m[1] < 0.01 then
        return m[2]
    end
end
return 30  -- final fallback
```

**Important**: FPS detection happens in BOTH drp_importer (for source_duration calc) AND drp_project_converter (for sequence fps). Both must use the same fps or audio durations will be wrong.

## Import Flow

```
drp_importer.parse_drp_file(path)
    ├── extract_drp()                  # Unzip to temp dir
    ├── parse_project_xml()            # Get project name
    ├── build_timeline_metadata_map()  # Sequence ID → {name, fps}
    ├── parse_media_pool_hierarchy()   # Bins + master clips
    └── parse_all_timelines()          # Tracks + clips
        └── parse_resolve_tracks()     # Per-sequence parsing (uses fps from metadata)

drp_project_converter.convert(parse_result, output_path)
    ├── Create new SQLite database
    ├── Insert project, sequences, tracks
    ├── Insert media (with file path lookup)
    ├── Insert clips (with unit conversion)
    └── Create A/V link groups
```

## Known Limitations

1. ~~**No FPS in XML**~~ - FIXED: FPS parsed from `<FrameRate>` hex in `<Sm2Sequence>`; 1-hour TC inference as fallback
2. ~~**No resolution metadata**~~ - FIXED: Resolution parsed from `<Resolution>` hex in `<Sm2Sequence>`
3. **No marks import** - In/out marks not yet supported
4. ~~**No A/V linking**~~ - FIXED: Clips grouped by `(file_path, timeline_start)` and linked via `clip_link.create_link_group()`
5. ~~**No rotation metadata**~~ - FIXED: Rotation extracted via FFmpeg `coded_side_data` display matrix; applied during timeline playback on clip switch
6. **Sample rate** - Uses media's rate if available, else 48kHz default

## Version Notes

Tested with DaVinci Resolve 18.x/19.x exports. XML schema may vary across versions.
