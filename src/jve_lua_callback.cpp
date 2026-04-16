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

    const char* err = lua_tostring(L, -1);
    if (err) {
        JVE_LOG_ERROR(Ui, "Lua callback error in %s: %s", where, err);
    } else {
        // The Lua error value was not a string (e.g. a table, userdata, nil
        // from a bare `error()`). Log its type so the message is still
        // actionable — the callsite name plus the error type narrows the
        // investigation to one handler.
        JVE_LOG_ERROR(Ui, "Lua callback error in %s: <non-string error of type %s>",
                      where, luaL_typename(L, -1));
    }
    lua_pop(L, 1);
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
