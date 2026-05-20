# Contract: `OpenClipInSourceMonitor`

**Spec source**: FR-017 | **Keybind**: `Shift+F` (FR-024) | **Also dispatched by**: timeline double-click (FR-026)

## SPEC.args

```lua
{
    clip_id     = { required = true, kind = "string" },
    project_id  = { required = true, kind = "string" },
    sequence_id = { required = true, kind = "string" },  -- the clip's OWNER sequence
}
```

`undoable = false`. View-state change; not on the undo stack.

## Executor

1. Resolve `source_viewer` via `require("ui.source_viewer")`.
2. Call `source_viewer.load_clip(args.clip_id)`.
3. Return `{ success = true }`.

## What this command DOES NOT do

- Does NOT mutate any model state.
- Does NOT focus the source monitor explicitly (load_clip internally calls `focus_manager.focus_panel("source_monitor")` per the existing pattern — same shape as today's `load_master_clip`).
- Does NOT change the timeline panel's active sequence.

## Tests (in `tests/test_open_clip_in_source_monitor.lua`)

- Happy path: dispatch command → `source_viewer.load_clip` called with `args.clip_id`.
- `undoable = false` verified (no undo entry created).
- Selection_hub publish: after dispatch, `selection_hub.get_selection("source_monitor")` returns `[{item_type="clip", clip_id=..., project_id=..., sequence_id=...}]` (per FR-028).
- Inspector pickup: simulating focus_manager.set_focused_panel("source_monitor") → inspector's update_selection invoked with the clip-schema item.
- Precondition: missing `clip_id` → command_manager rejects (existing SPEC validation).
