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
timecode_entry.compute_action(text, selected_ids, current_frame)
  → {command="SetPlayhead"|"Nudge", ...args}
```

Pure function (no signals, no DB). Centralises all TC entry dispatch branching in `core/` where it is testable without Qt. `apply_timecode_entry_text()` in the panel calls this and dispatches the result.

`JoinThroughEdit` persisted state (for undo):
```
per_join = {
    left_clip_id           -- string
    right_clip_snapshot    -- full Clip.load_v13_row result (all columns)
    left_original_duration -- integer frames
    left_original_source_out -- integer frames
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
