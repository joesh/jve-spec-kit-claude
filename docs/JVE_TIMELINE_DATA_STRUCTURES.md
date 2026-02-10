# JVE Timeline Data Structures

## Overview

JVE uses SQLite as its persistence layer with a relational model for timelines, tracks, and clips. All temporal coordinates are stored as **integers** representing frames or samples, with frame rate stored as metadata.

## Core Principle: Integer Coordinates

All temporal values are integers. Frame rate (fps) is metadata used only at I/O boundaries (import, export, timecode display). Edit operations work purely with integer arithmetic—no floating point, no Rational objects in the core.

```
┌─────────────────────────────────────────────────────────────┐
│                    Sequence (Timeline)                       │
│  fps_numerator/fps_denominator = 24/1                       │
│  audio_rate = 48000                                          │
├─────────────────────────────────────────────────────────────┤
│  VIDEO TRACK 1                                               │
│  ┌──────────────────────┐  ┌─────────────────────────────┐  │
│  │ Clip A               │  │ Clip B                      │  │
│  │ timeline_start=0     │  │ timeline_start=240          │  │
│  │ duration=240         │  │ duration=360                │  │
│  │ fps=24/1             │  │ fps=24/1                    │  │
│  └──────────────────────┘  └─────────────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│  AUDIO TRACK 1                                               │
│  ┌──────────────────────┐  ┌─────────────────────────────┐  │
│  │ Clip C               │  │ Clip D                      │  │
│  │ timeline_start=0     │  │ timeline_start=240          │  │
│  │ duration=240         │  │ duration=360                │  │
│  │ fps=48000/1          │  │ fps=48000/1                 │  │
│  │ source_in=0 (samp)   │  │ source_in=480000 (samp)    │  │
│  └──────────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Database Schema

### sequences

The top-level container for a timeline.

```sql
CREATE TABLE sequences (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id),
    name TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'timeline',  -- 'timeline', 'compound', 'multicam'

    -- Video Timebase (The Master Clock)
    fps_numerator INTEGER NOT NULL,    -- e.g., 24
    fps_denominator INTEGER NOT NULL,  -- e.g., 1

    -- Audio Rate
    audio_rate INTEGER NOT NULL,       -- e.g., 48000

    -- Dimensions
    width INTEGER NOT NULL,            -- e.g., 1920
    height INTEGER NOT NULL,           -- e.g., 1080

    -- Viewport State (integer frames)
    view_start_frame INTEGER NOT NULL DEFAULT 0,
    view_duration_frames INTEGER NOT NULL DEFAULT 240,
    playhead_frame INTEGER NOT NULL DEFAULT 0,

    -- Marks (nullable)
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,

    -- Selection State (JSON)
    selected_clip_ids TEXT DEFAULT '[]',
    selected_edge_infos TEXT DEFAULT '[]',
    selected_gap_infos TEXT DEFAULT '[]',

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);
```

**Key fields:**
- `fps_numerator/fps_denominator`: The timeline's video frame rate (e.g., 24/1, 30000/1001)
- `audio_rate`: Sample rate for audio (always 48000 currently)
- `playhead_frame`: Current playhead position in frames
- `view_start_frame/view_duration_frames`: Visible viewport in timeline UI

### tracks

Horizontal lanes within a sequence.

```sql
CREATE TABLE tracks (
    id TEXT PRIMARY KEY,
    sequence_id TEXT NOT NULL REFERENCES sequences(id),
    name TEXT NOT NULL,                -- e.g., "V1", "A1"
    track_type TEXT NOT NULL,          -- 'VIDEO' or 'AUDIO'
    track_index INTEGER NOT NULL,      -- 1-based index per type

    -- State
    enabled BOOLEAN NOT NULL DEFAULT 1,
    locked BOOLEAN NOT NULL DEFAULT 0,
    muted BOOLEAN NOT NULL DEFAULT 0,
    soloed BOOLEAN NOT NULL DEFAULT 0,

    -- Audio Mixer (ignored for VIDEO)
    volume REAL NOT NULL DEFAULT 1.0,
    pan REAL NOT NULL DEFAULT 0.0,

    UNIQUE(sequence_id, track_type, track_index)
);
```

**Track ordering:**
- `track_index` is 1-based and unique per type within a sequence
- VIDEO tracks are displayed above AUDIO tracks in the UI
- Lower index = higher visual position (V1 above V2)

### clips

The atomic unit of media on the timeline.

```sql
CREATE TABLE clips (
    id TEXT PRIMARY KEY,
    project_id TEXT REFERENCES projects(id),

    -- Structural
    clip_kind TEXT NOT NULL DEFAULT 'timeline',  -- 'master', 'timeline'
    source_sequence_id TEXT,           -- For compound/nested clips
    parent_clip_id TEXT,               -- Master→timeline relationship
    owner_sequence_id TEXT,            -- Direct ownership shortcut

    -- Container
    track_id TEXT REFERENCES tracks(id),

    -- Source
    media_id TEXT REFERENCES media(id),

    -- Naming
    name TEXT DEFAULT '',

    -- Timeline Position (INTEGER FRAMES)
    timeline_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- Source Selection (in clip.rate units)
    source_in_frame INTEGER NOT NULL DEFAULT 0,
    source_out_frame INTEGER NOT NULL,

    -- Self-Describing Timebase
    fps_numerator INTEGER NOT NULL,    -- Video: timeline fps; Audio: 48000
    fps_denominator INTEGER NOT NULL,  -- Usually 1

    -- State
    enabled BOOLEAN NOT NULL DEFAULT 1,
    offline BOOLEAN NOT NULL DEFAULT 0,

    -- Per-clip source marks
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,
    playhead_frame INTEGER NOT NULL DEFAULT 0,

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);
```

## Coordinate Systems

### Timeline Coordinates

All clips use **timeline frames** for positioning:

```
timeline_start_frame: Where the clip begins on the timeline
duration_frames: How long the clip appears on the timeline
```

These are always in the **sequence's frame rate** (e.g., 24fps).

### Source Coordinates

Source coordinates use the **clip's rate** (`fps_numerator/fps_denominator`):

```
source_in_frame: Start point in source media
source_out_frame: End point in source media
```

**For VIDEO clips:**
- `fps_numerator` = sequence fps (e.g., 24)
- `source_in/out` are in video frames

**For AUDIO clips:**
- `fps_numerator` = 48000 (sample rate)
- `source_in/out` are in audio samples

### Example: Audio Clip

```lua
-- 10-second audio clip starting at timeline second 5
{
    timeline_start_frame = 120,   -- 5 sec × 24 fps
    duration_frames = 240,        -- 10 sec × 24 fps

    source_in_frame = 0,          -- Start of audio file (samples)
    source_out_frame = 480000,    -- 10 sec × 48000 Hz

    fps_numerator = 48000,        -- Clip uses sample rate
    fps_denominator = 1,
}
```

### Time Conversion

To convert clip source coordinates to microseconds:

```lua
local time_us = source_frame * 1000000 * fps_denominator / fps_numerator
```

For audio (48000/1): `time_us = samples * 1000000 / 48000`
For video (24/1): `time_us = frames * 1000000 / 24`

## Clip Links (A/V Sync)

Clips can be linked for synchronized editing:

```sql
CREATE TABLE clip_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    link_group_id TEXT NOT NULL,
    clip_id TEXT NOT NULL REFERENCES clips(id),
    role TEXT NOT NULL DEFAULT 'video',  -- 'video', 'audio'
    time_offset INTEGER NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT 1
);
```

Linked clips move together during trim and move operations.

## Clip Kinds

```lua
clip_kind = "timeline"  -- Normal clip on timeline track
clip_kind = "master"    -- Master clip in bin (source reference)
```

Master clips represent media in the project's bin structure. Timeline clips can reference a master clip via `parent_clip_id`.

## Invariants

1. **timeline_start + duration = next_clip.timeline_start** (for contiguous clips)
2. **source_out - source_in ≤ media.duration** (can't exceed source length)
3. **duration_frames > 0** (enforced by CHECK constraint)
4. **All coordinates are integers** (no Rational objects in storage)
5. **fps_numerator/fps_denominator > 0** (enforced by CHECK)

## Playback Resolution

When playing back, the timeline resolver finds clips at a given frame:

```sql
SELECT * FROM clips
WHERE track_id = ?
  AND timeline_start_frame <= ?
  AND (timeline_start_frame + duration_frames) > ?
  AND enabled = 1
```

The query uses the timeline frame position and the clip's `timeline_start_frame` + `duration_frames` to determine coverage.

## Lua Model API

### Clip.create

```lua
local clip = Clip.create("Clip Name", media_id, {
    track_id = track.id,
    timeline_start = 0,
    duration = 240,
    source_in = 0,
    source_out = 240,
    fps_numerator = 24,
    fps_denominator = 1,
})
clip:save()
```

### Clip.load

```lua
local clip = Clip.load(clip_id)
-- Returns:
{
    id = "uuid",
    track_id = "track-uuid",
    media_id = "media-uuid",
    timeline_start = 0,
    duration = 240,
    source_in = 0,
    source_out = 240,
    rate = { fps_numerator = 24, fps_denominator = 1 },
    enabled = true,
    ...
}
```

### Clip.find_at_time

```lua
local clip = Clip.find_at_time(track_id, frame_position)
-- Returns first enabled clip containing that frame, or nil
```

### Sequence.create

```lua
local seq = Sequence.create("Timeline", project_id, {fps_numerator=24, fps_denominator=1}, 1920, 1080, {
    playhead_frame = 0,
    view_start_frame = 0,
    view_duration_frames = 480,
})
seq:save()
```

## Selection Model

Selection state is persisted in the sequence as JSON:

```lua
selected_clip_ids = '["clip-uuid-1", "clip-uuid-2"]'
selected_edge_infos = '[{"clip_id":"uuid","edge_type":"out","trim_type":"ripple"}]'
selected_gap_infos = '[{"track_id":"uuid","gap_start":100,"gap_end":200}]'
```

Edge selection includes:
- `clip_id`: The clip whose edge is selected
- `edge_type`: `"in"` or `"out"`
- `trim_type`: `"ripple"` or `"roll"`

## Undo/Redo

The `current_sequence_number` in sequences tracks undo state. Commands create snapshots of affected tables which are restored on undo.

## Performance Notes

- Clips are indexed by `track_id` for fast track queries
- `find_at_time` uses B-tree index on timeline_start_frame
- Bulk operations use transactions for consistency
