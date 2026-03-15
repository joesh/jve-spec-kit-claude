# Data Model: RelinkClips

No schema changes. All data uses existing structures.

## Entities

### Clip (existing — `clips` table)
- `id` TEXT PK
- `media_id` TEXT FK → media.id — **modified by RelinkClips** (may point to new media record)
- `source_in_frame` INTEGER — **modified by RelinkClips** (TC offset adjustment)
- `source_out_frame` INTEGER — **modified by RelinkClips** (TC offset adjustment)
- `clip_kind` TEXT — "master" or "timeline"
- `fps_numerator` / `fps_denominator` INTEGER — clip's native timebase

### Media (existing — `media` table)
- `id` TEXT PK
- `file_path` TEXT UNIQUE — **modified by RelinkClips** (new path) or **created** (segment files)
- `metadata` TEXT JSON — contains `start_tc_value` (integer frames), `start_tc_rate` (integer fps)
- `name`, `duration_frames`, `fps_numerator`, `fps_denominator`, `width`, `height`

### Project Settings (existing — `projects.settings` JSON column)
- New key: `relink_matching_rules`
```json
{
    "match_filename": true,
    "match_timecode": true,
    "match_resolution": false,
    "match_frame_rate": false,
    "accept_trimmed_media": false,
    "accept_filename_suffixes": false
}
```

### Command Undo State (existing — `commands.command_args` JSON column)
RelinkClips persists:
```json
{
    "clip_relink_map": {"clip_id": {"new_media_id": "...", "new_source_in": 100, "new_source_out": 300}},
    "old_clip_state": {"clip_id": {"old_media_id": "...", "old_source_in": 200, "old_source_out": 400}},
    "media_path_changes": {"media_id": "new/path"},
    "old_media_paths": {"media_id": "old/path"},
    "new_media_records": [{"id": "...", "path": "...", "name": "..."}]
}
```

## Relationships

```
Clip.media_id → Media.id (many-to-one)
Clip.master_clip_id → Sequence.id (master clip IS a sequence)
Media.metadata.start_tc → absolute TC origin of the file
```

## New Model Methods

### Clip
- `find_clips_for_media(media_id)` → array of Clip (all clip_kinds)
- `set_source_range(source_in, source_out)` → updates both fields + saves

### Media
- `get_start_tc()` → `(value, rate)` parsed from metadata JSON, or `(nil, nil)`
