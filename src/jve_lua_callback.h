#pragma once

// Shared helper for Lua pcall error handling in C++ callback contexts.
//
// Use this after EVERY lua_pcall() in a C++ callback invoked by Qt, by a
// worker thread's completion, by a QTimer, or by any other path that does
// not itself run inside an outer lua_pcall frame. Re-raising the error via
// lua_error() in those contexts escapes into C++ with no protected frame
// and crashes the process with "PANIC: unprotected error in call to Lua API".
//
// This helper logs the error (with a short `where` label for diagnostics)
// and pops it off the stack. The caller's C++ frame resumes normally and
// the event loop / Qt signal dispatch / worker completion continues.

struct lua_State;

// Drain a failed lua_pcall: log the error string on top of the stack via
// JVE_LOG_ERROR(Ui, ...) tagged with `where`, then pop it. Never throws,
// never calls lua_error. Safe from any thread that holds a valid lua_State.
//
// `where` should be a short stable identifier for the callsite (e.g.
// "mouse_press", "menu.triggered", "emp.codec_probe_batch") so log readers
// can identify which callback failed.
void jve_handle_lua_callback_error(lua_State* L, const char* where);

// Call after `lua_getglobal(L, handler_name)` when the result fails
// `lua_isfunction`. The caller has pushed a non-function value onto the
// stack; this helper logs the registration mismatch (a real bug — the
// handler name was set but the Lua global isn't a function) and pops it.
// Same rules as jve_handle_lua_callback_error: never throws, never asserts
// (the call is typically inside a Qt event handler with no protected frame
// above — crashing here would be worse than logging).
void jve_discard_non_function_handler(lua_State* L, const char* handler_name, const char* where);
