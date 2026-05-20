# Contract: `source_viewer` module public API (extended)

**Spec source**: FR-002..007, FR-013, FR-016a..f, FR-028..030, FR-004a/b

Not a command — module-level API consumed by command executors and other UI code.

## Public functions

### `M.load_sequence(sequence_id, opts)` — formerly `load_master_clip`

**Args**: `sequence_id : string` (any kind: media/clip); `opts : table | nil` with optional `skip_focus : bool`.

**Behavior**:
1. Asserts `sequence_id` non-empty.
2. Resolves source monitor via panel_manager; asserts present.
3. Records prev loaded entity for `source_loaded_changed` signal.
4. Calls `monitor:load_sequence(sequence_id)`.
5. Calls `transport.bind_role_to_sequence("source", sequence_id)`.
6. Publishes selection_hub item: `item_type="sequence"`, attached `sequence_id`, `project_id` (FR-028 staged-mode branch).
7. Emits `source_loaded_changed(sequence_id, prev_id)`.
8. If `not opts.skip_focus`, calls `focus_manager.focus_panel("source_monitor")`.
9. Sets `mode = "staged_sequence"`.

Returns `true`. Throws on assert failure (no soft return).

### `M.load_master_clip(sequence_id, opts)` — DEPRECATED alias

```lua
function M.load_master_clip(sequence_id, opts)
    -- DEPRECATED: alias retained for the 019→020 transition window.
    -- Spec 020 §FR-014 renames callers and removes this function.
    return M.load_sequence(sequence_id, opts)
end
```

### `M.load_clip(clip_id, opts)` — NEW

**Args**: `clip_id : string`; `opts : table | nil` with optional `skip_focus : bool`.

**Behavior**:
1. Asserts `clip_id` non-empty.
2. Loads the clip row (`Clip.load`); asserts non-nil.
3. Loads the clip's source sequence (`Sequence.load(clip.sequence_id)`); asserts non-nil.
4. Binds the source monitor by calling `monitor:load_sequence(clip.sequence_id)` — same code path staged mode uses (FR-005).
5. Stashes `clip_id` so the mark-setter dispatch and selection_hub publish know to read from clip columns instead of sequence-row marks.
6. Publishes selection_hub item: `item_type="clip"`, `clip_id`, `project_id`, `sequence_id` (the clip's OWNER) — FR-028.
7. Emits `source_loaded_changed(clip_id, prev_id)`.
8. If `not opts.skip_focus`, focuses source monitor.
9. Sets `mode = "live_bound_clip"`, `live_clip_id = clip_id`. (No `holding` field — the 2026-05-19 scope-trim dropped the in-memory holding sequence; playback binding goes through `clip.sequence_id` directly.)

Returns `true`. Throws on assert failure.

### `M.unload()` — UNCHANGED contract, EXTENDED behavior

**Behavior**:
1. If no entity loaded, return.
2. Clear `mode`, `staged_seq_id`, `live_clip_id`.
4. Call `monitor:unload()`.
5. Call `selection_hub.clear_selection("source_monitor")` (existing).
6. Emit `source_loaded_changed(nil, prev_id)` (existing).

### Internal: `M._on_clip_deleted(clip_id)` / `M._on_clip_mutated(clip_id)` — NEW listeners

**`_on_clip_deleted`** (FR-004a): if `clip_id == live_clip_id`, call `M.unload()`. No-op otherwise.

**`_on_clip_mutated`** (FR-004b): if `clip_id == live_clip_id`, re-read clip + source sequence via `Clip.load` / `Sequence.load`, update title (`sequence_monitor:_set_title(...)`), re-bind playback engine if rate/duration changed, republish selection_hub. No mode change.

### Internal: mark-setter dispatch (FR-013)

When `mode == "live_bound_clip"` and an I/O key event arrives (with `isAutoRepeat() == false` per FR-016b):

```
local mode = require("core.edit_mode").get_trim_mode()
local cmd  = (mode == "ripple") and "RippleTrimEdge" or "OverwriteTrimEdge"
local edge = is_in_mark and "left" or "right"
local delta = new_mark_frame - old_mark_frame
command_manager.execute_interactive(cmd, {
    clip_id      = state.live_clip_id,
    edge         = edge,
    delta_frames = delta,
    sequence_id  = clip.owner_sequence_id,
    project_id   = clip.project_id,
})
```

When `mode == "staged_sequence"`, use the existing `Sequence:set_in / set_out` path (unchanged by 019).

When `mode == "neutral"`, the I/O key is a no-op (no entity loaded).

### Internal: title computation (FR-016f)

```
mode == "staged_sequence":   title = string.format("Source: %s", sequence.name or sequence_id_prefix)
mode == "live_bound_clip":   title = string.format("Source: %s (in %s)", clip_label, owner.name or owner_id_prefix)
    where clip_label = (clip.name ~= nil and clip.name ~= "") and clip.name or clip_id_prefix
mode == "neutral":           title = "Source"
```

`clip_id_prefix` / `owner_id_prefix` are the first 8 chars of the respective id, matching SequenceMonitor's log convention.

## Tests

- `tests/test_source_viewer_load_clip.lua` (NEW, FR-031) — covers `load_clip` happy path, mode transition, selection_hub publish, mark-setter dispatch routing, **plus folded sub-FR scenarios**: key-repeat suppression (FR-016b), Play ignores marks (FR-016e), ClearMarks disabled (FR-016c), mutation re-resolve (FR-004b).
- `tests/test_source_viewer_publishes_selection.lua` (EXTEND) — add live-bound scenario alongside staged.
- `tests/test_source_viewer_signal.lua` (UNCHANGED) — staged-mode signal contract preserved.
