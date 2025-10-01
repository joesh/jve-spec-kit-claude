#include "timeline_ffi.h"
#include "../ui/timeline/scriptable_timeline.h"
#include <QDebug>

namespace JVE {

void TimelineFFI::register_functions(lua_State* L) {
    // Register timeline drawing functions with global names
    lua_register(L, "timeline_clear_commands", timeline_clear_commands);
    lua_register(L, "timeline_add_rect", timeline_add_rect);
    lua_register(L, "timeline_add_text", timeline_add_text);
    lua_register(L, "timeline_add_line", timeline_add_line);
    lua_register(L, "timeline_update", timeline_update);
    
    qDebug() << "TimelineFFI: Registered 5 timeline drawing functions with Lua";
}

ScriptableTimeline* TimelineFFI::get_timeline_widget(lua_State* L, int index) {
    // Get userdata and cast to ScriptableTimeline*
    // Lua validation should ensure this is valid before calling
    void** userdata = static_cast<void**>(lua_touserdata(L, index));
    if (!userdata || !*userdata) {
        return nullptr;
    }
    
    return static_cast<ScriptableTimeline*>(*userdata);
}

int TimelineFFI::timeline_clear_commands(lua_State* L) {
    ScriptableTimeline* timeline = get_timeline_widget(L, 1);
    
    if (timeline) {
        timeline->clearCommands();
        lua_pushboolean(L, true);
    } else {
        qDebug() << "TimelineFFI: No timeline widget - clearing commands skipped";
        lua_pushboolean(L, false);
    }
    return 1;
}

int TimelineFFI::timeline_add_rect(lua_State* L) {
    ScriptableTimeline* timeline = get_timeline_widget(L, 1);
    int x = lua_tointeger(L, 2);
    int y = lua_tointeger(L, 3);
    int width = lua_tointeger(L, 4);
    int height = lua_tointeger(L, 5);
    const char* color = lua_tostring(L, 6);
    
    if (timeline && color) {
        timeline->addRect(x, y, width, height, QString(color));
        lua_pushboolean(L, true);
    } else {
        lua_pushboolean(L, false);
    }
    return 1;
}

int TimelineFFI::timeline_add_text(lua_State* L) {
    ScriptableTimeline* timeline = get_timeline_widget(L, 1);
    int x = lua_tointeger(L, 2);
    int y = lua_tointeger(L, 3);
    const char* text = lua_tostring(L, 4);
    const char* color = lua_tostring(L, 5);
    
    if (timeline && text && color) {
        timeline->addText(x, y, QString(text), QString(color));
        lua_pushboolean(L, true);
    } else {
        lua_pushboolean(L, false);
    }
    return 1;
}

int TimelineFFI::timeline_add_line(lua_State* L) {
    ScriptableTimeline* timeline = get_timeline_widget(L, 1);
    int x1 = lua_tointeger(L, 2);
    int y1 = lua_tointeger(L, 3);
    int x2 = lua_tointeger(L, 4);
    int y2 = lua_tointeger(L, 5);
    const char* color = lua_tostring(L, 6);
    int width = lua_tointeger(L, 7);
    if (width == 0) width = 1; // Default line width
    
    if (timeline && color) {
        timeline->addLine(x1, y1, x2, y2, QString(color), width);
        lua_pushboolean(L, true);
    } else {
        lua_pushboolean(L, false);
    }
    return 1;
}

int TimelineFFI::timeline_update(lua_State* L) {
    ScriptableTimeline* timeline = get_timeline_widget(L, 1);
    
    if (timeline) {
        // Trigger a repaint to execute the drawing commands
        timeline->update();
        lua_pushboolean(L, true);
    } else {
        lua_pushboolean(L, false);
    }
    return 1;
}

} // namespace JVE