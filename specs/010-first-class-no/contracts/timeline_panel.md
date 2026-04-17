# Contract: `ui.timeline.timeline_panel`

## Changes

### New: `M.unload_sequence()`
```lua
--- Inverse of load_sequence. Transitions the panel into the no-active-sequence
--- state: clears timeline state, deactivates the command stack, blanks the
--- monitor, clears selection, and persists the empty tab settings.
function M.unload_sequence()
```
- **Precondition**: a project is open (project_id known to state). If no sequence is currently loaded, this is a no-op on the UI side but still persists the empty settings (idempotent).
- **Postconditions**:
  - `state.get_sequence_id() == nil`
  - `command_manager`'s active per-sequence stack is nil
  - Timeline monitor displays blank
  - `selection_hub.update_selection("timeline", {})` fired
  - `project_settings.last_open_sequence_id = ""`
  - `project_settings.open_sequence_ids = {}`
- **Invariant on save**: `#open_sequence_ids == 0 ⇔ last_open_sequence_id == ""`.

### Modified: `M.close_tab(sequence_id)`
- **Behavior change** at lines ~486–491 (the TODO hack):
  - When the tab being closed is the current active tab AND `tab_order` becomes empty, call `M.unload_sequence()`. Do not reopen a phantom tab.
- **Preconditions**: `sequence_id` is a string; tab may or may not currently exist.
- **Postconditions**:
  - Closed tab is removed from `open_tabs` and `tab_order`.
  - If another tab was next, that tab becomes active via `M.load_sequence(next_id)` (existing behavior, unchanged).
  - If no other tab exists, panel enters blank state via `M.unload_sequence()` (new).

### Modified: `M.create(opts)`
- **Contract change** at line ~1289–1290:
  - `opts.sequence_id` MAY be nil/empty. When nil, `create()` sets up widgets, skips `state.init`, calls `state.clear()` instead, and does not create an initial tab.
  - `opts.project_id` MUST be non-nil and non-empty (unchanged).
- **Postconditions**:
  - All Qt widgets are created and parented.
  - Tab bar container exists but is empty when `sequence_id` is nil.
  - No initial `ensure_tab_for_sequence` call when nil.
  - `state.get_sequence_id() == nil` when called with nil sequence_id.

### New: `M.handle_drop_on_blank_timeline(payload)`
```lua
--- Drop handler invoked when the user drops browser items onto the timeline
--- while in the no-active-sequence state.
--- @param payload table: {
---     clips = { clip_record, ... },      -- already flattened; bins recursed
---     sequences = { sequence_record, ... },
--- }
function M.handle_drop_on_blank_timeline(payload)
```
- **Behavior**:
  1. For each `sequences[i]`, call `M.open_tab(seq.id)` — last one becomes active.
  2. If `#clips > 0`:
     - Compute `name = build_drop_sequence_name(clips[1].name, #clips - 1)`.
     - Extract fps/resolution from `clips[1]` metadata; fall back to project defaults only if unusable.
     - In one `command_manager` undo group:
       - `seq_id = create_sequence(name, fps, width, height)`
       - For each clip: `insert_clip(seq_id, clip)` at the running playhead.
     - Open the new sequence as a tab and make it active.
  3. If both clips and sequences were dropped, the new-sequence tab becomes active last (so it is the active one).
- **Preconditions**: called only when `state.get_sequence_id() == nil`. Caller (`timeline_view_drag_handler`) enforces this.

### New helper: `build_drop_sequence_name(first_name, additional)`
```lua
--- Pure function. Testable in isolation without widgets.
--- additional == 0 → returns first_name.
--- additional >= 1 → returns first_name .. " (+" .. additional .. " more)".
```
- Exposed on the module table for test access.

## Required tests

- `tests/test_unload_sequence_persists_empty.lua`:
  - Seed `last_open_sequence_id = "s1"`, `open_sequence_ids = {"s1"}`.
  - Call `M.unload_sequence()`.
  - Assert settings now `""` and `{}` respectively; state cleared.
  - Idempotency: second call does not error; settings remain `""` and `{}`.
- `tests/test_drop_sequence_name_building.lua` (pure function):
  - `build_drop_sequence_name("clip.mov", 0) == "clip.mov"`.
  - `build_drop_sequence_name("clip.mov", 3) == "clip.mov (+3 more)"`.
  - `build_drop_sequence_name("a", 1) == "a (+1 more)"`.
- `tests/binding/test_close_last_tab_enters_blank.lua` (--test mode):
  - Open 1-seq project via `timeline_panel.create({sequence_id=s,project_id=p})`.
  - Call `close_tab(s)`.
  - Assert state cleared + DB persisted empty + no phantom tab reappeared.
