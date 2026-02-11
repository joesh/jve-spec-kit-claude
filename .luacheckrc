std = "max"

-- Broader checks; keep line-length relaxed for now.
max_line_length = false
unused_args = false
unused = true      -- include unused diagnostics
redefined = true   -- include redefined/shadow diagnostics

-- Ignore whitespace-only/trailing whitespace
ignore = {
    "611", "612", "613", "614",
}

globals = {
    -- Exposed by Qt/Lua bridge
    "qt_constants",
    "qt_set_focus",
    "qt_set_widget_click_handler",
    "qt_set_button_click_handler",
    "qt_set_context_menu_handler",
    "qt_set_line_edit_text_changed_handler",
    "qt_set_line_edit_editing_finished_handler",
    "qt_set_slider_value_changed_handler",
    "qt_set_checkbox_state_changed_handler",
    "qt_set_combobox_index_changed_handler",
    "qt_set_tree_widget_selection_changed_handler",
    "qt_set_table_widget_selection_changed_handler",
    "qt_set_header_view_section_resized_handler",
    "qt_set_widget_hover_handler",
    "qt_set_widget_focus_change_handler",
    "qt_set_range_slider_values_changed_handler",
    "qt_is_key_pressed",
    "qt_json_encode",
    "qt_json_decode",
    "qt_set_widget_attribute",
    "qt_update_widget",
    "qt_set_widget_stylesheet",
    "qt_set_widget_property",
    "qt_set_widget_contents_margins",
    "qt_set_object_name",
    "qt_set_focus_handler",
    "qt_set_focus_policy",
    "qt_set_splitter_moved_handler",
    "qt_hide_splitter_handle",
    "qt_set_scroll_area_anchor_bottom",
    "qt_get_splitter_handle",
    "qt_set_scroll_position",
    "qt_set_scroll_area_scroll_handler",
    "qt_set_widget_cursor",
    "qt_create_single_shot_timer",
    "qt_set_global_key_handler",
    "qt_set_layout_stretch_factor",
    "qt_show_dialog",
    "timeline",

    -- Bug reporter Qt bindings (from qt_bindings_bug_reporter.cpp)
    "install_gesture_logger",
    "set_gesture_logger_enabled",
    "grab_window",
    "create_timer",
    "post_mouse_event",
    "post_key_event",
    "sleep_ms",
    "process_events",
    "database",

    -- Runtime globals
    "jit",
}

exclude_files = {
    "build/**",
    "CMakeFiles/**",
    "src/lua/ui/keyboard_dialog_premiere.lua",
    "src/lua/ui/**/*.json",
    "**/.DS_Store",
    "**/*.cpp",
    "**/*.cpp.d",
    "**/*.h",
    "**/*.hpp",
    "**/*.c",
    "**/*.md",
    "**/*.txt",
    "**/*.json",
    "**/*.moc",
    "**/*.moc.d",
    "**/*.mp4",
    "**/*.xml",
    "**/*.sh",
    "**/*.sql",
    "**/*.db",
    "**/*.png",
    "**/*.jpg",
    "**/*.jpeg",
    "**/*.gif",
    "**/*.webp",
    "**/*.wav",
    "**/*.mp3",
    "**/*.mov",
    "**/*.avi",
    "**/*.drp",
    "**/*.jvp",
    ".git/**",
    -- autogen contains Qt moc files, not Lua
    "tests/autogen/**",
    -- ad_hoc tests are incomplete/experimental
    "tests/ad_hoc/**",
    -- fixture files are test data, not Lua
    "tests/fixtures/**",
    -- captures contains screenshot PNGs and recordings
    "tests/captures/**",
}

include_files = {
    "src/lua/**",
    "tests/**",
}

files = {
    ["src/lua/dkjson.lua"] = {
        -- Third-party JSON library - suppress all warnings
        ignore = { "211", "212", "213", "311", "312", "411", "421", "431" },
    },
    ["src/lua/core/command_implementations.lua"] = {
        ignore = { "211", "311", "241", "421", "431", "511" },
    },
    ["src/lua/core/command_manager.lua"] = {
        ignore = { "211", "311", "431" },
    },
    ["src/lua/ui/timeline/timeline_view.lua"] = {
        ignore = { "211", "212", "213", "231", "241", "311", "321", "331", "421", "431" },
    },
    ["src/lua/ui/timeline/timeline_panel.lua"] = {
        ignore = { "211", "212", "213", "231", "241", "311", "321", "331", "421", "431" },
    },
    ["src/lua/ui/project_browser.lua"] = {
        ignore = { "211", "212", "213", "231", "241", "311", "321", "331", "421", "431" },
    },
}
