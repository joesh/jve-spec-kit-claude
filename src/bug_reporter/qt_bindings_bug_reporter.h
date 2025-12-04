#pragma once

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

namespace bug_reporter {

/**
 * Register bug reporter Qt bindings with Lua state.
 * Called from main initialization.
 */
void registerBugReporterBindings(lua_State* L);

} // namespace bug_reporter
