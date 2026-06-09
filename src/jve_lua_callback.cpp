#include "jve_lua_callback.h"
#include "jve_log.h"
#include "assert_handler.h"

#include <cstdio>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

void jve_handle_lua_callback_error(lua_State* L, const char* where)
{
    // Loud-but-non-terminating: an unhandled Lua error reaching this
    // bridge IS an invariant violation, but the C++ bridge sits inside
    // a Qt slot lambda — throwing or _exit'ing would terminate the
    // editor and lose the user's session. Policy (CLAUDE.md §1.14
    // + Joe 2026-05-20): print the Lua stack trace to stderr
    // unconditionally so it shows up in Terminal Saved Output, then
    // return. The Lua side already asserted with context; this bridge
    // makes sure the message + traceback are not invisible.
    //
    // History: previous version called JVE_LOG_ERROR (gated by
    // JVE_LOG env var → invisible by default), which hid real bugs
    // for arbitrarily long because the user surface was "the keypress
    // did nothing." Direct stderr is the right home — always-on,
    // appears in the developer's terminal regardless of log-area
    // settings.
    const char* where_str = where ? where : "<unknown>";
    if (L == nullptr) {
        fprintf(stderr,
            "\n[Lua callback error in %s] lua_State is null in callback bridge\n",
            where_str);
        fflush(stderr);
        return;
    }

    // Stack progression:
    //   start:                      [..., original_err]
    //   after err_str push:         [..., original_err, err_str]
    //   after luaL_traceback:       [..., original_err, err_str, traceback]
    if (lua_isstring(L, -1) || lua_isnumber(L, -1)) {
        lua_pushvalue(L, -1);
    } else {
        lua_pushfstring(L, "<%s>", luaL_typename(L, -1));
    }
    const char* err_str = lua_tostring(L, -1);
    luaL_traceback(L, L, err_str, /*level=*/ 1);
    const char* trace = lua_tostring(L, -1);

    fprintf(stderr,
        "\n╔══════════════════════════════════════════════════════════════╗\n"
        "║                  LUA CALLBACK ERROR                          ║\n"
        "╚══════════════════════════════════════════════════════════════╝\n"
        "  Location: %s\n%s\n\n",
        where_str, trace ? trace : "<no traceback>");
    fflush(stderr);

    lua_pop(L, 3);  // pop traceback, err_str, original error
}

void jve_invoke_lua_callback(lua_State* L, int ref,
                             std::function<int(lua_State*)> push_args,
                             const char* where)
{
    // ref == LUA_NOREF is a valid lifecycle state — the binding has no
    // callback registered yet (or it was already unrefed); silent no-op
    // is correct. L == nullptr with a valid ref is an invariant
    // violation: a binding wired a Qt signal without capturing its
    // lua_State. Surface loudly via stderr (same loud-but-non-terminating
    // policy as jve_handle_lua_callback_error above — a hard assert would
    // kill the editor mid-slot and lose Joe's session).
    if (ref == LUA_NOREF) return;
    if (L == nullptr) {
        fprintf(stderr,
            "\n[jve_invoke_lua_callback @ %s] lua_State is null but ref=%d is valid"
            " — binding wired a signal without capturing L\n",
            where ? where : "<unknown>", ref);
        fflush(stderr);
        return;
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    int n = push_args(L);
    if (lua_pcall(L, n, 0, 0) != 0) {
        jve_handle_lua_callback_error(L, where);
    }
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
