# Contract: Lua-Callback Bridge — Stack Trace Logging

**Status**: tightened existing C++ function · **Spec ref**: FR-008, FR-009 · **Phase 1**

## What changes

`jve_handle_lua_callback_error` (`src/jve_lua_callback.cpp`) currently logs the bare error message:

```cpp
const char* err = lua_tostring(L, -1);
JVE_LOG_ERROR(Ui, "Lua callback error in %s: %s", where, err);
```

Update it to capture a Lua stack trace before logging:

```cpp
// luaL_tolstring handles non-string errors by invoking __tostring or
// the generic fallback — guarantees a string representation regardless
// of error type (string, table, userdata, number, nil).
//
// Stack progression:
//   start: [..., original_err]
//   after luaL_tolstring: [..., original_err, err_str]
//   after luaL_traceback: [..., original_err, err_str, traceback]
const char* err_str = luaL_tolstring(L, -1, NULL);
luaL_traceback(L, L, err_str, /*level=*/ 1);
JVE_LOG_ERROR(Ui, "Lua callback error in %s: %s", where, lua_tostring(L, -1));
lua_pop(L, 3);  // pop traceback, err_str, and the original error
```

Rationale: matches the JVE_ASSERT semantic — loud and actionable (the log line points to the exact failing frame), but non-fatal (the editor stays up). This is the rule-VI deviation tracked in plan.md Complexity Tracking. `luaL_tolstring` handles rule 1.12 (external inputs must never crash) — even an error table without a `__tostring` metamethod produces a usable diagnostic string instead of a NULL deref.

## Behavior contract

- **Input**: a Lua error is on top of the stack `L` (already there per `lua_pcall` failure convention).
- **Output**: log line `[ui] ERROR: Lua callback error in <where>: <error_msg>\nstack traceback:\n\t<frame>...` and the Lua stack is restored to its pre-call height (error popped).
- **Side effects**: nothing else. Editor process continues. The Qt slot or signal handler that triggered the error returns normally.
- **Behavior on non-string errors** (table, userdata, nil from bare `error()`): `luaL_tolstring` produces a usable string representation via `__tostring` metamethod or generic fallback. The traceback is appended below it. The existing `<non-string error of type %s>` fallback path is removed — it's redundant once `luaL_tolstring` is in place.

## Coverage

The change is to a single function. Every callsite of `jve_handle_lua_callback_error` automatically gets the new behavior. Known callsites at planning time (verify exhaustively in Phase 4 with `grep -rn 'jve_handle_lua_callback_error\b' src/`):

- `src/lua/qt_bindings/control_bindings.cpp` (combobox.current_index_changed; button_box.accepted; button_box.rejected)
- `src/lua/qt_bindings/fs_watcher_bindings.cpp` (fs.file_changed; fs.dir_changed)
- `src/timeline_renderer.cpp` (TimelineRenderer.mouse_press; TimelineRenderer.mouse_release)
- Plus any others surfaced by the Phase 4 grep.

## Out of scope

- The conversion-dialog `convert_fn` direct-call site (`src/lua/ui/conversion_dialog.lua:208`). That site bypasses the C++ bridge entirely (it's a Lua-to-Lua call). It was separately fixed earlier this session by adding a `pcall` wrapper on the Lua side. This contract covers only the C++ bridge.
- Adding a UI-surface for callback errors (option D in clarification Q1). That's a separate feature; not required by FR-008.

## Test contract

1. **Traceback presence test**: install a Qt signal handler that calls a Lua function which deliberately calls `error("synthetic test error")`. Trigger the signal. Assert: TSO contains `Lua callback error in <signal>: synthetic test error\nstack traceback:` AND at least one frame line below it.

2. **Editor-still-running test**: same as above, but after the error, perform another normal operation. Assert: it succeeds — the editor was not killed.

3. **Non-string error test**: Lua handler calls `error({reason="test"})`. Assert: log line still includes a usable description (luaL_traceback's output for the table value plus the full traceback).
