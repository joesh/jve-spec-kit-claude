# Contract: `ToggleTrimMode`

**Spec source**: FR-011 | **Default keybind**: none (UI placement deferred)

## SPEC.args

```lua
{
    -- No args. Pure toggle.
}
```

`undoable = false`. UI/process state; not on the undo stack.

## Executor

1. `local current = edit_mode.get_trim_mode()` — asserts non-nil (FR-009).
2. `local next = (current == "overwrite") and "ripple" or "overwrite"`.
3. `edit_mode.set_trim_mode(next)` — emits `trim_mode_changed` signal.
4. Return `{ success = true }`.

## Side effects

- `core/edit_mode` state flips.
- `trim_mode_changed` signal emitted with `(new_mode, old_mode)` payload.
- Any listener (future status-bar indicator, etc.) reacts.

## Tests (in `tests/test_edit_mode_toggle.lua`)

- Initial state: `get_trim_mode() == "overwrite"`.
- After dispatch: `get_trim_mode() == "ripple"`.
- After two dispatches: back to `"overwrite"`.
- Signal verification: `trim_mode_changed` fires with the right payload.
- Session-transient: after `_reset_for_tests()`, mode is back to `"overwrite"` (FR-010).
- Enum-guard: `set_trim_mode("bogus")` asserts (FR-009).
