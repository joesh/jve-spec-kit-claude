# Data Model: 025-Five Timeline UX Improvements

No new persisted entities. All changes are to existing data or transient UI state.

---

## Existing entities touched

### `timeline_state.lua` — colors table
Add one constant:
```
THROUGH_EDIT_MARKER = "#e83030"
```

### `clips` table (SQLite)
No schema change. `JoinThroughEdit` mutates existing columns via `Clip.update_bounds()`:
- `sequence_start_frame`, `duration_frames`, `source_in_frame`, `source_out_frame` on the surviving (left) clip.
- Row deletion for the absorbed (right) clip via `Clip.delete_one()`.

Same-source identity (FR-001 detection) reads the master track reference: `master_layer_track_id` (video clips) / `master_audio_track_id` (audio clips). Spec 021 later renames these to `source_video_track_id` / `source_audio_track_id`; 025 uses the current names.

### `clip_markers` table (SQLite)
No schema change. `JoinThroughEdit` reassigns the absorbed (right) clip's `clip_markers.clip_id` to the surviving (left) clip **before** deleting the right clip — `clip_markers.clip_id` has `ON DELETE CASCADE`, so the markers would be lost otherwise. Reassigned ids are recorded for undo. (No keyframe table exists.)

---

## Transient state

### TC entry mode (`timeline_panel.lua`)
Module-local flag `tc_entry_mode` — one of `nil`, `"offset"`, `"goto"`. Set when `IncrementTimecode`/`DecrementTimecode`/`GoToTimecode` activates the field; cleared on `editing_finished`. Drives red-border stylesheet. Not persisted.

---

## New commands (no new DB tables)

| Command | Undoable | Args |
|---|---|---|
| `JoinThroughEdit` | yes | `sequence_id`, `edit_frame`, `track_id` |
| `JoinAllThroughEdits` | yes | `sequence_id` |
| `IncrementTimecode` | no | `project_id`, `sequence_id` |
| `DecrementTimecode` | no | `project_id`, `sequence_id` |
| `GoToTimecode` | no | `project_id`, `sequence_id` |
| `ExclusiveToggleTrackPreference` | no | `track_id`, `property`, `project_id`, `sequence_id` |

`timecode_entry.lua` also exports a pure helper used by `timeline_panel.lua`:

```
timecode_entry.compute_action(text, selected_clip_ids, selected_edges, current_frame)
  → {command="SetPlayhead", playhead_position=N}        -- "=" or empty-selection offset
  → {command="Nudge", nudge_amount=N,                    -- "+"/"-" with selection
       selected_clip_ids=…, selected_edges=…}
```

Pure function (no signals, no DB). Centralises all TC entry dispatch branching in `core/` where it is testable without Qt. `SetPlayhead`'s arg is `playhead_position` (integer frame), not `frame`. `Nudge` carries both `selected_clip_ids` and `selected_edges` (it moves clips and edges). `apply_timecode_entry_text()` in the panel calls this — passing `timeline_state.get_selected_clip_ids()` / `get_selected_edges()` — and dispatches the result.

`JoinThroughEdit` persisted state (for undo):
```
per_join = {
    left_clip_id             -- string
    right_clip_snapshot      -- full Clip.load_v13_row result (all columns)
    left_original_duration   -- integer frames
    left_original_source_out -- integer frames
    migrated_marker_ids      -- clip_markers ids reassigned right→left; moved back on undo
}
```

---

## New C++ binding

| Symbol | File | Returns |
|---|---|---|
| `qt_constants.INPUT.GET_KEYBOARD_MODIFIERS` | `qt_bindings.cpp` | `{alt=bool, shift=bool, ctrl=bool, meta=bool}` |

Qt modifier constants stay in C++. Lua reads `.alt` directly — no bitmask in Lua (Rule 1.5, Rule 2.18).

---

## Keybindings (default.jvekeys additions)

```toml
"Plus"    = "IncrementTimecode @timeline"
"Num+"    = "IncrementTimecode @timeline"
"Minus"   = "DecrementTimecode @timeline"
"Num-"    = "DecrementTimecode @timeline"
"Equal"   = "GoToTimecode @timeline"
```
