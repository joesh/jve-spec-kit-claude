#pragma once

#include <lua.hpp>

namespace QtControls {

    // Click handler functions
    int qt_set_button_click_handler(lua_State* L);
    int qt_set_line_edit_text_changed_handler(lua_State* L);
    int qt_set_widget_click_handler(lua_State* L);

    // Registration function
    void register_bindings(lua_State* L);
}