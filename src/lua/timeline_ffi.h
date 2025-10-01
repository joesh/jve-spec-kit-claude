#pragma once

#include <lua.hpp>

namespace JVE {

/**
 * FFI bindings for timeline drawing commands
 * Allows Lua scripts to control timeline graphics by sending drawing commands to C++
 */
class TimelineFFI
{
public:
    // Register all timeline FFI functions with Lua
    static void register_functions(lua_State* L);
    
    // Timeline drawing command functions
    static int timeline_clear_commands(lua_State* L);
    static int timeline_add_rect(lua_State* L);
    static int timeline_add_text(lua_State* L);
    static int timeline_add_line(lua_State* L);
    static int timeline_update(lua_State* L);
    
private:
    // Helper to get ScriptableTimeline widget from Lua userdata
    static class ScriptableTimeline* get_timeline_widget(lua_State* L, int index);
};

} // namespace JVE