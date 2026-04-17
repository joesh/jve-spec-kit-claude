# Contract: `core.command_manager`

## Changes

### New: `M.deactivate()`
```lua
--- Drop the currently-active per-sequence command stack. Called when the
--- editor enters the no-active-sequence state (close-last-tab, sequence
--- delete, project open without tabs).
function M.deactivate()
```
- **Preconditions**: `init()` was previously called. If no active stack is currently set, this is a no-op.
- **Postconditions**:
  - Internal "active timeline stack" reference is nil.
  - Per-sequence stacks for all sequences remain persisted (not discarded) — FR-014: undoing a sequence delete must restore its stack.
  - `M.execute(cmd)` on a per-sequence command fails fast (assert) when called with no active stack — caller must nil-guard.
  - `M.undo()` / `M.redo()` with no active stack routes to the project-level stack (see below).
- **Idempotent**: safe to call multiple times.

### Modified: `M.undo()` / `M.redo()`
- **Behavior change**: when the active per-sequence stack is nil, dispatch falls through to the project-level stack.
  - If the project-level stack is empty or absent, both are no-ops (no error, no toast).
  - If a project-level command exists, it is popped and applied/inverted as usual.
- **Rationale**: FR-012 — project-scoped actions (sequence CRUD, bin operations) remain undo-reachable in blank state.

### Modified: `M.init(sequence_id, project_id)`
- **Contract unchanged** in argument strictness — both still required non-nil.
- **Interaction**: callers that previously called `init` on project open now may call `init(seq, pid)` OR `deactivate()` depending on whether a last-active sequence was resolvable.

### Modified: `M.activate_timeline_stack(sequence_id)`
- **Contract unchanged**: still requires a non-nil sequence_id.
- **New sibling**: `M.deactivate()` (above) is the inverse.

## Required tests

- `tests/test_command_manager_deactivate.lua`:
  - Init with sequence "s1"; execute a per-sequence command.
  - Call `deactivate()`.
  - Assert that `undo()` does NOT undo the per-sequence command (it stays on the disk-backed per-sequence stack, untouched).
  - Execute a project-level command (e.g., `create_sequence`).
  - Call `undo()`; assert the project-level command was reverted.
- `tests/test_command_manager_undo_routes_to_project_when_blank.lua`:
  - After `deactivate()`, `undo()` and `redo()` operate on the project stack only.
  - With both stacks empty, `undo()` is a no-op (no error).
