# Contract: `ui.timeline.timeline_state`

## Changes

### New: `state.clear()`
```lua
--- Clear the active-sequence reference. The project_id is left intact
--- because blank state is scoped within an open project.
--- Notifies listeners so pull-based consumers re-query.
function M.clear()
```
- **Precondition**: module was previously `init`'d (i.e., project_id is set). Calling `clear()` when never-initialized is a no-op.
- **Postconditions**:
  - `M.get_sequence_id()` → `nil`
  - `M.get_project_id()` → unchanged
  - `M.get_selected_clips()` → `{}`
  - `M.get_mark_in()`, `M.get_mark_out()`, `M.get_playhead()` → nil / defaults
  - Listeners registered via `add_listener` are invoked once (so inspector/monitors can re-pull and render blank).
- **Does not touch**: `project_id`, project-scoped prefs, listener registrations themselves.
- **Idempotent**: calling `clear()` twice is safe; the second call still fires listeners.

### Modified: `state.init(sequence_id, project_id)`
- **Contract unchanged.** Both arguments remain required (non-nil, non-empty). Calling `init(nil, nil)` still asserts.
- **Interaction**: calling `init(new_seq, same_pid)` after `clear()` is the standard transition out of the blank state.

### Existing accessors — new nullable return type

| Accessor | Before | After |
|---|---|---|
| `get_sequence_id()` | `string` | `string \| nil` |
| `get_project_id()` | `string` | `string \| nil` (nil only when no project open) |
| `get_selected_clips()` | `table` (possibly empty) | unchanged |

Callers MUST handle `nil` on `get_sequence_id()` — the data-model.md lists all known call sites.

## Required tests

- `tests/test_timeline_state_clear.lua`:
  - After `init("s1", "p1")`, `clear()`; assert `get_sequence_id() == nil` and `get_project_id() == "p1"` (project retained).
  - After `clear()`, `init("s2", "p1")`; assert `get_sequence_id() == "s2"`.
  - Listener is called on `clear()`; registered via `add_listener(fn)`.
  - Calling `clear()` before any `init` is a no-op (does not error).
