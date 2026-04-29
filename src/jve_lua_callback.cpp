#include "jve_lua_callback.h"
#include "jve_log.h"
#include "assert_handler.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

void jve_handle_lua_callback_error(lua_State* L, const char* where)
{
    JVE_ASSERT(L != nullptr, "jve_handle_lua_callback_error: lua_State is null");
    JVE_ASSERT(where != nullptr, "jve_handle_lua_callback_error: where label is required");

    // Capture a Lua stack trace before logging. Matches JVE_ASSERT semantics:
    // loud and actionable (the trace points to the failing frame), but
    // non-fatal (the editor stays running so the user keeps their session).
    //
    // Build a string representation of the error first. lua_tostring works
    // for strings and numbers; for tables / userdata / nil (e.g. from a
    // bare `error()`), push a "<type>" placeholder so the traceback still
    // appears with a usable diagnostic. LuaJIT 2.1 lacks luaL_tolstring
    // (Lua 5.2+); this emulation matches its observable behavior for the
    // cases that matter (string errors and the long tail of non-strings).
    //
    // Stack progression:
    //   start:                      [..., original_err]
    //   after err_str push:         [..., original_err, err_str]
    //   after luaL_traceback:       [..., original_err, err_str, traceback]
    if (lua_isstring(L, -1) || lua_isnumber(L, -1)) {
        lua_pushvalue(L, -1);  // duplicate; lua_tostring on the copy is safe
    } else {
        lua_pushfstring(L, "<%s>", luaL_typename(L, -1));
    }
    const char* err_str = lua_tostring(L, -1);
    luaL_traceback(L, L, err_str, /*level=*/ 1);
    JVE_LOG_ERROR(Ui, "Lua callback error in %s: %s", where, lua_tostring(L, -1));
    lua_pop(L, 3);  // pop traceback, err_str, and the original error
}

void jve_discard_non_function_handler(lua_State* L, const char* handler_name, const char* where)
{
    JVE_ASSERT(L != nullptr, "jve_discard_non_function_handler: lua_State is null");
    JVE_ASSERT(where != nullptr, "jve_discard_non_function_handler: where label is required");

    JVE_LOG_ERROR(Ui, "Missing handler in %s: global '%s' is %s, not a function",
                  where,
                  handler_name ? handler_name : "(null)",
                  luaL_typename(L, -1));
    lua_pop(L, 1);
}
