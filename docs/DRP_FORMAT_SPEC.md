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
    <Sm2Sequence DbId="abc-123-..."/>  <!-- Links to SeqContainer file -->
  </Sequence>
</Sm2Timeline>
```

**Key fields:**
- `DbId` - Unique identifier for the timeline object
- `Name` - Display name shown in Resolve's UI
- `Sequence/Sm2Sequence@DbId` - Reference to sequence data in SeqContainer/

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
| `FrameRate` | `sequences.fps_numerator/fps_denominator` | Inferred from 1-hour TC |
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

DRP stores frame rate in binary `FieldsBlob` which is difficult to parse. JVE infers fps from the earliest clip's Start position using the 1-hour timecode convention:

| Start Frame | Frame Rate | Notes |
|-------------|------------|-------|
| ~86,314 | 23.976 fps | NTSC film (24000/1001) |
| 86,400 | 24 fps | True film |
| 90,000 | 25 fps | PAL |
| ~107,892 | 29.97 fps | NTSC video (30000/1001) |
| 108,000 | 30 fps | |

**Detection algorithm** (with 1% tolerance):
```lua
local markers = {
    { 86400, 24 },   -- 24 fps
    { 86314, 24 },   -- 23.976 (treat as 24)
    { 90000, 25 },   -- 25 fps
    { 108000, 30 },  -- 30 fps
    { 107892, 30 },  -- 29.97 (treat as 30)
}
for _, m in ipairs(markers) do
    if math.abs(min_start - m[1]) / m[1] < 0.01 then
        return m[2]
    end
end
return 30  -- fallback
```

**Important**: This inference happens in BOTH drp_importer (for source_duration calc) AND drp_project_converter (for sequence fps). Both must use the same inferred fps or audio durations will be wrong.

## Import Flow

```
drp_importer.parse_drp_file(path)
    ├── extract_drp()           # Unzip to temp dir
    ├── parse_project_xml()     # Get project name
    ├── build_timeline_name_map() # Sequence ID → Name
    ├── parse_media_pool_hierarchy() # Bins + master clips
    └── parse_all_timelines()   # Tracks + clips
        └── parse_resolve_tracks() # Per-sequence parsing

drp_project_converter.convert(parse_result, output_path)
    ├── Create new SQLite database
    ├── Insert project, sequences, tracks
    ├── Insert media (with file path lookup)
    └── Insert clips (with unit conversion)
```

## Known Limitations

1. **No FPS in XML** - Frame rate inferred from timecode, may fail for non-standard starts
2. **No resolution metadata** - Defaults to 1920×1080
3. **No marks import** - In/out marks not yet supported
4. **No A/V linking** - Sync groups not preserved
5. **No rotation metadata** - Phone footage orientation lost
6. **Sample rate assumed** - Always 48kHz

## Version Notes

Tested with DaVinci Resolve 18.x/19.x exports. XML schema may vary across versions.
