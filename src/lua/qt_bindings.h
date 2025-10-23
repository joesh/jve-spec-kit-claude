#pragma once

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

// Forward declaration
class SimpleLuaEngine;

/**
 * Qt bindings for Lua
 * Provides real Qt widget creation and management from Lua
 */

// Register all Qt bindings with the Lua state
void registerQtBindings(lua_State* L);

// JSON functions
int lua_json_encode(lua_State* L);
int lua_json_decode(lua_State* L);

// Widget creation functions
int lua_create_main_window(lua_State* L);
int lua_create_widget(lua_State* L);
int lua_create_scroll_area(lua_State* L);
int lua_create_label(lua_State* L);
int lua_create_line_edit(lua_State* L);
int lua_create_button(lua_State* L);
int lua_create_checkbox(lua_State* L);
int lua_create_combobox(lua_State* L);
int lua_create_slider(lua_State* L);
int lua_create_tree_widget(lua_State* L);
int lua_create_timeline_panel(lua_State* L);
int lua_create_inspector_panel(lua_State* L);

// Layout functions
int lua_create_hbox_layout(lua_State* L);
int lua_create_vbox_layout(lua_State* L);
int lua_create_splitter(lua_State* L);
int lua_set_layout(lua_State* L);
int lua_add_widget_to_layout(lua_State* L);
int lua_add_stretch_to_layout(lua_State* L);
int lua_set_central_widget(lua_State* L);
int lua_set_splitter_sizes(lua_State* L);

// Property functions
int lua_set_text(lua_State* L);
int lua_get_text(lua_State* L);
int lua_set_checked(lua_State* L);
int lua_get_checked(lua_State* L);
int lua_add_combobox_item(lua_State* L);
int lua_set_combobox_current_text(lua_State* L);
int lua_get_combobox_current_text(lua_State* L);
int lua_set_slider_range(lua_State* L);
int lua_set_slider_value(lua_State* L);
int lua_get_slider_value(lua_State* L);
int lua_set_placeholder_text(lua_State* L);
int lua_set_window_title(lua_State* L);
int lua_set_size(lua_State* L);
int lua_set_geometry(lua_State* L);
int lua_set_style_sheet(lua_State* L);

// Display functions
int lua_show_widget(lua_State* L);
int lua_set_visible(lua_State* L);
int lua_raise_widget(lua_State* L);
int lua_activate_window(lua_State* L);

// Control functions
int lua_set_scroll_area_widget(lua_State* L);
int lua_set_scroll_area_viewport_margins(lua_State* L);

// Tree widget functions
int lua_set_tree_headers(lua_State* L);
int lua_set_tree_column_width(lua_State* L);
int lua_set_tree_indentation(lua_State* L);
int lua_add_tree_item(lua_State* L);
int lua_add_tree_child_item(lua_State* L);
int lua_get_tree_selected_index(lua_State* L);
int lua_clear_tree(lua_State* L);
int lua_set_tree_item_expanded(lua_State* L);
int lua_set_tree_item_data(lua_State* L);
int lua_get_tree_item_data(lua_State* L);
int lua_set_tree_selection_changed_handler(lua_State* L);
int lua_set_tree_item_icon(lua_State* L);
int lua_set_tree_item_double_click_handler(lua_State* L);

// Signal handling functions
int lua_set_button_click_handler(lua_State* L);
int lua_set_widget_click_handler(lua_State* L);
int lua_set_tree_item_click_handler(lua_State* L);
int lua_set_line_edit_text_changed_handler(lua_State* L);
int lua_set_global_key_handler(lua_State* L);
int lua_set_focus_handler(lua_State* L);
int lua_set_focus_policy(lua_State* L);
int lua_set_focus(lua_State* L);

// Layout styling functions
int lua_set_layout_spacing(lua_State* L);
int lua_set_layout_margins(lua_State* L);
int qt_set_layout_alignment(lua_State* L);
int lua_set_widget_size_policy(lua_State* L);
int lua_set_layout_stretch_factor(lua_State* L);
int lua_set_widget_alignment(lua_State* L);

// Widget relationship functions
int lua_set_parent(lua_State* L);

// Widget attribute functions
int lua_set_widget_attribute(lua_State* L);

// Utility functions
void* lua_to_widget(lua_State* L, int index);
void lua_push_widget(lua_State* L, void* widget);
