#include "qt_bindings.h"
#include "simple_lua_engine.h" // Needed for SimpleLuaEngine::s_lastCreatedMainWindow

// Include all the newly split binding files. These files contain the implementations
// of the Lua C functions and are compiled as part of this module.
#include "lua/qt_bindings/binding_macros.h" // For get_widget template and other macros
#include "lua/qt_bindings/widget_bindings.cpp"
#include "lua/qt_bindings/layout_bindings.cpp"
#include "lua/qt_bindings/control_bindings.cpp"
#include "lua/qt_bindings/view_bindings.cpp"
#include "lua/qt_bindings/signal_bindings.cpp"
#include "lua/qt_bindings/json_bindings.cpp"
#include "lua/qt_bindings/menu_bindings.cpp"
#include "lua/qt_bindings/dialog_bindings.cpp"
#include "lua/qt_bindings/misc_bindings.cpp"
#include "lua/qt_bindings/emp_bindings.cpp"
#include "lua/qt_bindings/aop_bindings.cpp"
#include "lua/qt_bindings/sse_bindings.cpp"

// Define the metatable name (declared extern in qt_bindings.h)
const char* WIDGET_METATABLE = "JVE.Widget";

// Public helper functions to convert between Lua userdata and C++ QWidget pointers.
// These are defined here because they are common to all bindings and rely on WIDGET_METATABLE.
// Declared in qt_bindings.h.
void* lua_to_widget(lua_State* L, int index)
{
    if (!lua_isuserdata(L, index)) {
        luaL_error(L, "Expected widget userdata at index %d", index);
        return nullptr;
    }
    
    void** widget_ptr = (void**)luaL_checkudata(L, index, WIDGET_METATABLE);
    return *widget_ptr;
}

void lua_push_widget(lua_State* L, void* widget)
{
    if (!widget) {
        lua_pushnil(L);
        return;
    }
    
    void** widget_ptr = (void**)lua_newuserdata(L, sizeof(void*));
    *widget_ptr = widget;
    luaL_getmetatable(L, WIDGET_METATABLE);
    lua_setmetatable(L, -2);
}


// Main registration function. This function is called by SimpleLuaEngine to expose
// all Qt-related functionality to the Lua environment.
void registerQtBindings(lua_State* L)
{
    // Create widget metatable (must be done once for all QWidget userdatas)
    // This metatable defines how Lua interacts with C++ QWidget objects.
    luaL_newmetatable(L, WIDGET_METATABLE);
    lua_pop(L, 1);
    
    // Create the global 'qt_constants' table in Lua
    lua_newtable(L);
    
    // Populate 'qt_constants.WIDGET' subtable with widget creation and manipulation functions
    lua_newtable(L);
    lua_pushcfunction(L, lua_create_main_window); lua_setfield(L, -2, "CREATE_MAIN_WINDOW");
    lua_pushcfunction(L, lua_create_widget); lua_setfield(L, -2, "CREATE");
    lua_pushcfunction(L, lua_create_scroll_area); lua_setfield(L, -2, "CREATE_SCROLL_AREA");
    lua_pushcfunction(L, lua_create_label); lua_setfield(L, -2, "CREATE_LABEL");
    lua_pushcfunction(L, lua_create_line_edit); lua_setfield(L, -2, "CREATE_LINE_EDIT");
    lua_pushcfunction(L, lua_create_button); lua_setfield(L, -2, "CREATE_BUTTON");
    lua_pushcfunction(L, lua_create_checkbox); lua_setfield(L, -2, "CREATE_CHECKBOX");
    lua_pushcfunction(L, lua_create_combobox); lua_setfield(L, -2, "CREATE_COMBOBOX");
    lua_pushcfunction(L, lua_create_slider); lua_setfield(L, -2, "CREATE_SLIDER");
    lua_pushcfunction(L, lua_create_tree_widget); lua_setfield(L, -2, "CREATE_TREE");
    lua_pushcfunction(L, lua_create_timeline_renderer); lua_setfield(L, -2, "CREATE_TIMELINE");
    lua_pushcfunction(L, lua_create_inspector_panel); lua_setfield(L, -2, "CREATE_INSPECTOR");
    lua_pushcfunction(L, lua_create_rubber_band); lua_setfield(L, -2, "CREATE_RUBBER_BAND");
    lua_pushcfunction(L, lua_set_rubber_band_geometry); lua_setfield(L, -2, "SET_RUBBER_BAND_GEOMETRY");
    lua_pushcfunction(L, lua_grab_mouse); lua_setfield(L, -2, "GRAB_MOUSE");
    lua_pushcfunction(L, lua_release_mouse); lua_setfield(L, -2, "RELEASE_MOUSE");
    lua_pushcfunction(L, lua_map_point_from); lua_setfield(L, -2, "MAP_POINT_FROM");
    lua_pushcfunction(L, lua_map_rect_from); lua_setfield(L, -2, "MAP_RECT_FROM");
    lua_pushcfunction(L, lua_map_to_global); lua_setfield(L, -2, "MAP_TO_GLOBAL");
    lua_pushcfunction(L, lua_map_from_global); lua_setfield(L, -2, "MAP_FROM_GLOBAL");
    lua_pushcfunction(L, lua_set_parent); lua_setfield(L, -2, "SET_PARENT");
    lua_setfield(L, -2, "WIDGET");
    
    // Populate 'qt_constants.LAYOUT' subtable with layout management functions
    lua_newtable(L);
    lua_pushcfunction(L, lua_create_hbox_layout); lua_setfield(L, -2, "CREATE_HBOX");
    lua_pushcfunction(L, lua_create_vbox_layout); lua_setfield(L, -2, "CREATE_VBOX");
    lua_pushcfunction(L, lua_create_splitter); lua_setfield(L, -2, "CREATE_SPLITTER");
    lua_pushcfunction(L, lua_set_layout); lua_setfield(L, -2, "SET_ON_WIDGET");
    lua_pushcfunction(L, lua_add_widget_to_layout); lua_setfield(L, -2, "ADD_WIDGET");
    lua_pushcfunction(L, lua_add_stretch_to_layout); lua_setfield(L, -2, "ADD_STRETCH");
    lua_pushcfunction(L, lua_set_central_widget); lua_setfield(L, -2, "SET_CENTRAL_WIDGET");
    lua_pushcfunction(L, lua_set_splitter_sizes); lua_setfield(L, -2, "SET_SPLITTER_SIZES");
    lua_pushcfunction(L, lua_get_splitter_sizes); lua_setfield(L, -2, "GET_SPLITTER_SIZES");
    lua_pushcfunction(L, lua_set_splitter_stretch_factor); lua_setfield(L, -2, "SET_SPLITTER_STRETCH_FACTOR");
    lua_setfield(L, -2, "LAYOUT");
    
    // Populate 'qt_constants.PROPERTIES' subtable with widget property functions
    lua_newtable(L);
    lua_pushcfunction(L, lua_set_text_generic); lua_setfield(L, -2, "SET_TEXT");
    lua_pushcfunction(L, lua_get_text_generic); lua_setfield(L, -2, "GET_TEXT");
    lua_pushcfunction(L, lua_set_checked); lua_setfield(L, -2, "SET_CHECKED");
    lua_pushcfunction(L, lua_get_checked); lua_setfield(L, -2, "GET_CHECKED");
    lua_pushcfunction(L, lua_add_combobox_item); lua_setfield(L, -2, "ADD_COMBOBOX_ITEM");
    lua_pushcfunction(L, lua_set_combobox_current_text); lua_setfield(L, -2, "SET_COMBOBOX_CURRENT_TEXT");
    lua_pushcfunction(L, lua_get_combobox_current_text); lua_setfield(L, -2, "GET_COMBOBOX_CURRENT_TEXT");
    lua_pushcfunction(L, lua_set_slider_range); lua_setfield(L, -2, "SET_SLIDER_RANGE");
    lua_pushcfunction(L, lua_set_slider_value); lua_setfield(L, -2, "SET_SLIDER_VALUE");
    lua_pushcfunction(L, lua_get_slider_value); lua_setfield(L, -2, "GET_SLIDER_VALUE");
    lua_pushcfunction(L, lua_set_placeholder_text); lua_setfield(L, -2, "SET_PLACEHOLDER_TEXT");
    lua_pushcfunction(L, lua_set_window_title); lua_setfield(L, -2, "SET_TITLE");
    lua_pushcfunction(L, lua_set_size); lua_setfield(L, -2, "SET_SIZE");
    lua_pushcfunction(L, lua_get_widget_size); lua_setfield(L, -2, "GET_SIZE");
    lua_pushcfunction(L, lua_set_minimum_width); lua_setfield(L, -2, "SET_MIN_WIDTH");
    lua_pushcfunction(L, lua_set_maximum_width); lua_setfield(L, -2, "SET_MAX_WIDTH");
    lua_pushcfunction(L, lua_set_minimum_height); lua_setfield(L, -2, "SET_MIN_HEIGHT");
    lua_pushcfunction(L, lua_set_maximum_height); lua_setfield(L, -2, "SET_MAX_HEIGHT");
    lua_pushcfunction(L, lua_set_geometry); lua_setfield(L, -2, "SET_GEOMETRY");
    lua_pushcfunction(L, lua_get_geometry); lua_setfield(L, -2, "GET_GEOMETRY");
    lua_pushcfunction(L, lua_set_widget_stylesheet); lua_setfield(L, -2, "SET_STYLE");
    lua_pushcfunction(L, lua_set_window_appearance); lua_setfield(L, -2, "SET_WINDOW_APPEARANCE");
    lua_pushcfunction(L, lua_set_widget_cursor); lua_setfield(L, -2, "SET_CURSOR");
    lua_setfield(L, -2, "PROPERTIES");
    
    // Populate 'qt_constants.DISPLAY' subtable with widget display functions
    lua_newtable(L);
    lua_pushcfunction(L, lua_show_widget); lua_setfield(L, -2, "SHOW");
    lua_pushcfunction(L, lua_set_visible); lua_setfield(L, -2, "SET_VISIBLE");
    lua_pushcfunction(L, lua_raise_widget); lua_setfield(L, -2, "RAISE");
    lua_pushcfunction(L, lua_activate_window); lua_setfield(L, -2, "ACTIVATE");
    lua_setfield(L, -2, "DISPLAY");
    
    // Populate 'qt_constants.CONTROL' subtable with various control functions
    lua_newtable(L);
    lua_pushcfunction(L, lua_set_scroll_area_widget); lua_setfield(L, -2, "SET_SCROLL_AREA_WIDGET");
    lua_pushcfunction(L, lua_set_scroll_area_viewport_margins); lua_setfield(L, -2, "SET_SCROLL_AREA_VIEWPORT_MARGINS");
    lua_pushcfunction(L, lua_set_scroll_area_widget_resizable); lua_setfield(L, -2, "SET_SCROLL_AREA_WIDGET_RESIZABLE");
    lua_pushcfunction(L, lua_set_scroll_area_h_scrollbar_policy); lua_setfield(L, -2, "SET_SCROLL_AREA_H_SCROLLBAR_POLICY");
    lua_pushcfunction(L, lua_set_scroll_area_v_scrollbar_policy); lua_setfield(L, -2, "SET_SCROLL_AREA_V_SCROLLBAR_POLICY");
    lua_pushcfunction(L, lua_set_layout_spacing); lua_setfield(L, -2, "SET_LAYOUT_SPACING");
    lua_pushcfunction(L, lua_set_layout_margins); lua_setfield(L, -2, "SET_LAYOUT_MARGINS");
    lua_pushcfunction(L, lua_set_widget_size_policy); lua_setfield(L, -2, "SET_WIDGET_SIZE_POLICY");
    lua_pushcfunction(L, lua_set_button_click_handler); lua_setfield(L, -2, "SET_BUTTON_CLICK_HANDLER");
    lua_pushcfunction(L, lua_set_widget_click_handler); lua_setfield(L, -2, "SET_WIDGET_CLICK_HANDLER");
    lua_pushcfunction(L, lua_set_context_menu_handler); lua_setfield(L, -2, "SET_CONTEXT_MENU_HANDLER");
    lua_pushcfunction(L, lua_set_tree_headers); lua_setfield(L, -2, "SET_TREE_HEADERS");
    lua_pushcfunction(L, lua_set_tree_column_width); lua_setfield(L, -2, "SET_TREE_COLUMN_WIDTH");
    lua_pushcfunction(L, lua_set_tree_indentation); lua_setfield(L, -2, "SET_TREE_INDENTATION");
    lua_pushcfunction(L, lua_set_tree_expands_on_double_click); lua_setfield(L, -2, "SET_TREE_EXPANDS_ON_DOUBLE_CLICK");
    lua_pushcfunction(L, lua_add_tree_item); lua_setfield(L, -2, "ADD_TREE_ITEM");
    lua_pushcfunction(L, lua_add_tree_child_item); lua_setfield(L, -2, "ADD_TREE_CHILD_ITEM");
    lua_pushcfunction(L, lua_get_tree_selected_index); lua_setfield(L, -2, "GET_TREE_SELECTED_INDEX");
    lua_pushcfunction(L, lua_clear_tree); lua_setfield(L, -2, "CLEAR_TREE");
    lua_pushcfunction(L, lua_set_tree_item_expanded); lua_setfield(L, -2, "SET_TREE_ITEM_EXPANDED");
    lua_pushcfunction(L, lua_is_tree_item_expanded); lua_setfield(L, -2, "IS_TREE_ITEM_EXPANDED");
    lua_pushcfunction(L, lua_set_tree_item_data); lua_setfield(L, -2, "SET_TREE_ITEM_DATA");
    lua_pushcfunction(L, lua_get_tree_item_data); lua_setfield(L, -2, "GET_TREE_ITEM_DATA");
    lua_pushcfunction(L, lua_set_tree_item_text); lua_setfield(L, -2, "SET_TREE_ITEM_TEXT");
    lua_pushcfunction(L, lua_set_tree_item_editable); lua_setfield(L, -2, "SET_TREE_ITEM_EDITABLE");
    lua_pushcfunction(L, lua_edit_tree_item); lua_setfield(L, -2, "EDIT_TREE_ITEM");
    lua_pushcfunction(L, lua_set_tree_selection_changed_handler); lua_setfield(L, -2, "SET_TREE_SELECTION_HANDLER");
    lua_pushcfunction(L, lua_set_tree_item_changed_handler); lua_setfield(L, -2, "SET_TREE_ITEM_CHANGED_HANDLER");
    lua_pushcfunction(L, lua_set_tree_close_editor_handler); lua_setfield(L, -2, "SET_TREE_CLOSE_EDITOR_HANDLER");
    lua_pushcfunction(L, lua_set_tree_selection_mode); lua_setfield(L, -2, "SET_TREE_SELECTION_MODE");
    lua_pushcfunction(L, lua_set_tree_drag_drop_mode); lua_setfield(L, -2, "SET_TREE_DRAG_DROP_MODE");
    lua_pushcfunction(L, lua_set_tree_drop_handler); lua_setfield(L, -2, "SET_TREE_DROP_HANDLER");
    lua_pushcfunction(L, lua_set_tree_key_handler); lua_setfield(L, -2, "SET_TREE_KEY_HANDLER");
    lua_pushcfunction(L, lua_set_tree_item_icon); lua_setfield(L, -2, "SET_TREE_ITEM_ICON");
    lua_pushcfunction(L, lua_set_tree_item_double_click_handler); lua_setfield(L, -2, "SET_TREE_DOUBLE_CLICK_HANDLER");
    lua_pushcfunction(L, lua_set_tree_current_item); lua_setfield(L, -2, "SET_TREE_CURRENT_ITEM");
    lua_pushcfunction(L, lua_get_tree_item_at); lua_setfield(L, -2, "GET_TREE_ITEM_AT");
    lua_setfield(L, -2, "CONTROL");
    
    // Register global signal functions for direct access in Lua (e.g., qt_set_button_click_handler)
    lua_pushcfunction(L, lua_set_button_click_handler); lua_setglobal(L, "qt_set_button_click_handler");
    lua_pushcfunction(L, lua_set_widget_click_handler); lua_setglobal(L, "qt_set_widget_click_handler");
    lua_pushcfunction(L, lua_set_context_menu_handler); lua_setglobal(L, "qt_set_context_menu_handler");
    lua_pushcfunction(L, lua_set_line_edit_text_changed_handler); lua_setglobal(L, "qt_set_line_edit_text_changed_handler");
    lua_pushcfunction(L, lua_set_line_edit_editing_finished_handler); lua_setglobal(L, "qt_set_line_edit_editing_finished_handler");
    lua_pushcfunction(L, lua_line_edit_select_all); lua_setglobal(L, "qt_line_edit_select_all");
    lua_pushcfunction(L, lua_set_tree_selection_changed_handler); lua_setglobal(L, "qt_set_tree_selection_handler");
    lua_pushcfunction(L, lua_set_tree_selection_mode); lua_setglobal(L, "qt_set_tree_selection_mode");
    lua_pushcfunction(L, lua_set_tree_drag_drop_mode); lua_setglobal(L, "qt_set_tree_drag_drop_mode");
    lua_pushcfunction(L, lua_set_tree_drop_handler); lua_setglobal(L, "qt_set_tree_drop_handler");
    lua_pushcfunction(L, lua_set_tree_key_handler); lua_setglobal(L, "qt_set_tree_key_handler");
    lua_pushcfunction(L, lua_is_tree_item_expanded); lua_setglobal(L, "qt_is_tree_item_expanded");
    lua_pushcfunction(L, lua_set_tree_item_icon); lua_setglobal(L, "qt_set_tree_item_icon");
    lua_pushcfunction(L, lua_set_tree_item_double_click_handler); lua_setglobal(L, "qt_set_tree_item_double_click_handler");
    lua_pushcfunction(L, lua_set_tree_expands_on_double_click); lua_setglobal(L, "qt_set_tree_expands_on_expands_on_double_click");
    lua_pushcfunction(L, lua_get_tree_item_at); lua_setglobal(L, "qt_get_tree_item_at");
    lua_pushcfunction(L, lua_hide_splitter_handle); lua_setglobal(L, "qt_hide_splitter_handle");
    lua_pushcfunction(L, lua_set_splitter_moved_handler); lua_setglobal(L, "qt_set_splitter_moved_handler");
    lua_pushcfunction(L, lua_get_splitter_handle); lua_setglobal(L, "qt_get_splitter_handle");
    lua_pushcfunction(L, lua_update_widget); lua_setglobal(L, "qt_update_widget");

    // Register scroll functions globally
    lua_pushcfunction(L, lua_get_scroll_position); lua_setglobal(L, "qt_get_scroll_position");
    lua_pushcfunction(L, lua_set_scroll_position); lua_setglobal(L, "qt_set_scroll_position");
    lua_pushcfunction(L, lua_set_scroll_area_scroll_handler); lua_setglobal(L, "qt_set_scroll_area_scroll_handler");

    // Register new database binding functions

    // Register JSON functions globally
    lua_pushcfunction(L, lua_json_encode); lua_setglobal(L, "qt_json_encode");
    lua_pushcfunction(L, lua_json_decode); lua_setglobal(L, "qt_json_decode");

    // Register other global utility functions
    lua_pushcfunction(L, lua_set_layout_stretch_factor); lua_setglobal(L, "qt_set_layout_stretch_factor");
    lua_pushcfunction(L, lua_set_widget_alignment); lua_setglobal(L, "qt_set_widget_alignment");
    lua_pushcfunction(L, qt_set_layout_alignment); lua_setglobal(L, "qt_set_layout_alignment");
    lua_pushcfunction(L, lua_set_parent); lua_setglobal(L, "qt_set_parent");
    lua_pushcfunction(L, lua_set_widget_attribute); lua_setglobal(L, "qt_set_widget_attribute");
    lua_pushcfunction(L, lua_set_object_name); lua_setglobal(L, "qt_set_object_name");
    lua_pushcfunction(L, lua_set_widget_stylesheet); lua_setglobal(L, "qt_set_widget_stylesheet");
    lua_pushcfunction(L, lua_set_widget_cursor); lua_setglobal(L, "qt_set_widget_cursor");
    lua_pushcfunction(L, lua_set_window_appearance); lua_setglobal(L, "qt_set_window_appearance");
    lua_pushcfunction(L, lua_create_single_shot_timer); lua_setglobal(L, "qt_create_single_shot_timer");
    lua_pushcfunction(L, lua_set_scroll_area_alignment); lua_setglobal(L, "qt_set_scroll_area_alignment");
    lua_pushcfunction(L, lua_set_scroll_area_anchor_bottom); lua_setglobal(L, "qt_set_scroll_area_anchor_bottom");
    lua_pushcfunction(L, lua_set_focus_policy); lua_setglobal(L, "qt_set_focus_policy");
    lua_pushcfunction(L, lua_set_focus); lua_setglobal(L, "qt_set_focus");
    lua_pushcfunction(L, lua_set_global_key_handler); lua_setglobal(L, "qt_set_global_key_handler");
    lua_pushcfunction(L, lua_set_focus_handler); lua_setglobal(L, "qt_set_focus_handler");
    lua_pushcfunction(L, lua_show_confirm_dialog); lua_setglobal(L, "qt_show_confirm_dialog");
    lua_pushcfunction(L, lua_show_dialog); lua_setglobal(L, "qt_show_dialog");
    lua_pushcfunction(L, lua_show_menu_popup); lua_setglobal(L, "qt_show_menu_popup");

    // Populate 'qt_constants.MENU' subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_get_menu_bar); lua_setfield(L, -2, "GET_MENU_BAR");
    lua_pushcfunction(L, lua_create_menu); lua_setfield(L, -2, "CREATE_MENU");
    lua_pushcfunction(L, lua_add_menu_to_bar); lua_setfield(L, -2, "ADD_MENU_TO_BAR");
    lua_pushcfunction(L, lua_add_submenu); lua_setfield(L, -2, "ADD_SUBMENU");
    lua_pushcfunction(L, lua_create_menu_action); lua_setfield(L, -2, "CREATE_MENU_ACTION");
    lua_pushcfunction(L, lua_connect_menu_action); lua_setfield(L, -2, "CONNECT_MENU_ACTION");
    lua_pushcfunction(L, lua_add_menu_separator); lua_setfield(L, -2, "ADD_MENU_SEPARATOR");
    lua_pushcfunction(L, lua_set_action_enabled); lua_setfield(L, -2, "SET_ACTION_ENABLED");
    lua_pushcfunction(L, lua_set_action_checked); lua_setfield(L, -2, "SET_ACTION_CHECKED");
    lua_pushcfunction(L, lua_set_action_text); lua_setfield(L, -2, "SET_ACTION_TEXT");
    lua_pushcfunction(L, lua_show_menu_popup); lua_setfield(L, -2, "SHOW_POPUP");
    lua_setfield(L, -2, "MENU");

    // Populate 'qt_constants.DIALOG' subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_show_confirm_dialog); lua_setfield(L, -2, "SHOW_CONFIRM");
    lua_setfield(L, -2, "DIALOG");

    // Populate 'qt_constants.EMP' subtable (Editor Media Platform - video decoding)
    register_emp_bindings(L);

    // Populate 'qt_constants.AOP' subtable (Audio Output Platform)
    register_aop_bindings(L);

    // Populate 'qt_constants.SSE' subtable (Scrub Stretch Engine)
    register_sse_bindings(L);

    // Populate 'qt_constants.FILE_DIALOG' subtable
    lua_newtable(L);
    lua_pushcfunction(L, lua_file_dialog_open); lua_setfield(L, -2, "OPEN_FILE");
    lua_pushcfunction(L, lua_file_dialog_open_multiple); lua_setfield(L, -2, "OPEN_FILES");
    lua_pushcfunction(L, lua_file_dialog_directory); lua_setfield(L, -2, "OPEN_DIRECTORY");
    lua_setfield(L, -2, "FILE_DIALOG");

    // Populate 'qt_constants.SIGNAL' subtable for application-level signal handlers
    lua_newtable(L);
    lua_pushcfunction(L, lua_set_geometry_change_handler); lua_setfield(L, -2, "SET_GEOMETRY_CHANGE_HANDLER");
    lua_setfield(L, -2, "SIGNAL");

    // Set the 'qt_constants' global table
    lua_setglobal(L, "qt_constants");
}
