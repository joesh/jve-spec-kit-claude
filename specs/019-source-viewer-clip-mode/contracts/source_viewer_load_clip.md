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

**Args**: `clip_id : string`; `opts : table | nil` with:
- `skip_focus : bool` — skip the focus-panel side effect.
- `playhead_frame : number` — park the source-side playhead at this frame (in `clip.sequence_id`'s frame space). **Caller-supplied, no fallback masking the absence.** When omitted, defaults to `clip.source_in`. The Shift+F dispatch path (`OpenClipInSourceMonitor` per FR-024) reads the record-tab playhead and passes it here so the source tab + source viewer stay in sync with where the user was on the record side (FR-024 v2, 2026-05-22 amendment).

**Behavior**:
1. Asserts `clip_id` non-empty.
2. Loads the clip row (`Clip.load`); asserts non-nil.
3. Loads the clip's source sequence (`Sequence.load(clip.sequence_id)`); asserts non-nil.
4. **Writes `effective_source._source_viewer_seq_id/in/out` via `_set_source_viewer_clip(clip.sequence_id, clip.source_in, clip.source_out)`.** Must happen BEFORE step 5 — `monitor:load_sequence` fires the source monitor's listener, which the source-side mark bar subscribes to. The mark bar's render reads marks via `SequenceMonitor:get_mark_in/out`, which now consult `effective_source.get_source_marks_for`. If the override isn't populated yet, the first render draws no marks and the bar stays empty until the user incidentally seeks (manual repro 2026-05-21: marks didn't appear until playhead moved). `effective_source` has no state dependency on the source viewer mode flag — safe to write before the transition.
5. Binds the source monitor by calling `monitor:load_sequence(clip.sequence_id)` — same code path staged mode uses (FR-005).
6. Calls `transport.bind_role_to_sequence("source", clip.sequence_id)`.
7. **Writes the master row's `playhead_position` via `core.playhead.set(clip.sequence_id, target_frame)`** where `target_frame = opts.playhead_frame or clip.source_in`. This is a single canonical model write — the master sequence's row (which the source tab's ruler reads) is updated atomically with the engine seek, because `transport`'s `playhead_changed` listener picks up the signal and seeks the source engine bound in step 6. No view/model drift, no double-seek.
8. Stashes `clip_id` so the mark-setter dispatch and selection_hub publish know to read from clip columns instead of sequence-row marks.
9. Publishes selection_hub item: `item_type="clip"`, `clip_id`, `project_id`, `sequence_id` (the clip's OWNER) — FR-028.
10. Emits `source_loaded_changed(clip.sequence_id, prev_id)`. **Signal payload is always the SOURCE SEQUENCE id**, never `clip_id` — `timeline_panel`'s auto-source-tab handler and `effective_source.on_source_loaded_changed` both interpret arg1 as a sequence id; passing `clip_id` here keyed the auto-opened tab on a clip identity and clobbered `effective_source._source_viewer_seq_id` (just-written by `_set_source_viewer_clip`) with the wrong namespace. Clip identity is carried separately through `selection_hub` publish (step 9) + `effective_source` override fields (`_source_viewer_in/out`).
11. If `not opts.skip_focus`, focuses source monitor.
12. Sets `mode = "live_bound_clip"`, `live_clip_id = clip_id`. (No `holding` field — the 2026-05-19 scope-trim dropped the in-memory holding sequence; playback binding goes through `clip.sequence_id` directly.)

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

### `M.get_mode()` — public mode accessor

Returns one of `"neutral"`, `"staged_sequence"`, `"live_bound_clip"`. Documented as part of the public API so tests can verify mode transitions without inspecting internal fields (black-box).

### `M.get_live_clip_id()` / `M.get_staged_seq_id()` — mode accessors

Pure model getters returning the currently-loaded clip id (live-bound mode) or sequence id (staged mode), or nil when not in that mode. Consumed by source-monitor-scoped commands (`SetMarkAndTrimIfClip`) that need the loaded entity identity without reaching into module-private state.

### I/O key dispatch — owned by `SetMarkAndTrimIfClip`, not source_viewer

The dispatch logic that was sketched here in pre-implementation drafts (`M.handle_mark_key`) has been moved into the `SetMarkAndTrimIfClip` command (`src/lua/core/commands/set_mark_and_trim_if_clip.lua`). `source_viewer` exposes only model accessors; the command owns the mode-aware dispatch.

**Keymap routing**: I/O keys are bound in `keymaps/default.jvekeys` to *two different commands* on disjoint scopes:

- `"I" = "SetMark in @timeline @timeline_monitor"` / `"O" = "SetMark out @timeline @timeline_monitor"` — plain `SetMark` is pure: it always mutates the addressed sequence row's `mark_in`/`mark_out`. No source-viewer awareness, no hidden branches.
- `"I" = "SetMarkAndTrimIfClip in @source_monitor"` / `"O" = "SetMarkAndTrimIfClip out @source_monitor"` — `SetMarkAndTrimIfClip` is the source-monitor variant. Internally it reads `source_viewer.get_mode()` and dispatches a nested command:
  - `live_bound_clip` → dispatches `OverwriteTrimEdge` (or `RippleTrimEdge` per `edit_mode.get_trim_mode()`) on the loaded clip's leading/trailing edge with `delta_frames = playhead - clip.source_in/out`. The clip's `source_in`/`source_out` IS the mark in live-bound mode; there is no sequence row to mutate.
  - `staged_sequence` → dispatches a nested `SetMark` on the staged sequence row (so the mutation rides the proper undo stack with `SetMark`'s undoer, not a duplicated implementation here).
  - `neutral` → no-op.

The two scopes are disjoint, so the keymap registry has no precedence rules to resolve. The command name in each scope is honest about what it does there. `SetMarkAndTrimIfClip` is `SPEC.undoable = false`, so the outer wrapper never persists an empty entry on the undo stack — only the nested `SetMark` / `OverwriteTrimEdge` / `RippleTrimEdge` does, and that's the entry the user undoes.

Auto-repeat suppression (FR-016b) lives at `keyboard_shortcuts.lua` and the C++ `shortcut_bindings.cpp` event filter — events with `isAutoRepeat()==true` are dropped before reaching any command dispatch.

### Internal: mark-setter dispatch (FR-013)

```lua
-- inside set_mark_and_trim_if_clip.lua, live-bound branch
local clip_id = sv.get_live_clip_id()  -- asserts non-nil in live-bound mode
local clip    = require("models.clip").load(clip_id)
local edge    = (which == "in") and "left" or "right"
local current = (which == "in") and clip.source_in or clip.source_out
local delta   = frame - current
if delta == 0 then return end  -- mark already at playhead — no-op

local cmd_name = (require("core.edit_mode").get_trim_mode() == "ripple")
    and "RippleTrimEdge" or "OverwriteTrimEdge"
command_manager.execute_interactive(cmd_name, {
    clip_id      = clip.id,
    edge         = edge,
    delta_frames = delta,
    sequence_id  = clip.owner_sequence_id,
    project_id   = clip.project_id,
})
```

`staged_sequence` branch dispatches a nested `SetMark`; `neutral` is a no-op.

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
