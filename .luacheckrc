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
    "qt_get_focus_widget",
    "qt_get_widget_property",
    "qt_widget_child_widget_count",
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
    "qt_xml_parse",
    "qt_xml_parse_string",
    "qt_zstd_decompress",
    "qt_zstd_compress",
    -- spec 023 T032 — ASC CDL math test binding (regression target for
    -- both emp::apply_cdl_rgb and the mirrored Metal fragment shader).
    "qt_cdl_apply_pixel",
    -- spec 023 LUT3D math test bindings (parser + sampler regression target,
    -- mirrored CPU/Metal in emp_lut3d.cpp).
    "qt_lut3d_parse_string",
    "qt_lut3d_apply_pixel",
    "qt_lut3d_free",
    -- spec 024 — BT.709 color-space conversion math test binding.
    "qt_compose_bt709_csc",
    -- spec 023 — Resolve-bridge client process identity (QCoreApplication::applicationPid).
    "qt_get_pid",
    -- spec 027 T001 — build provenance for bug reporter (git SHA at compile time).
    "qt_get_build_info",
    -- spec 027 T010b — QPixmap dimension accessors used by bug-reporter capture tests.
    "qpixmap_width",
    "qpixmap_height",
    -- spec 027 T007 + T030 — bug-reporter crypto (SHA-256 and HMAC-SHA256).
    "qt_sha256",
    "qt_hmac_sha256",
    -- spec 023 — helper_supervisor wait_for_bind: replaces test/sleep shellouts.
    "qt_thread_msleep",
    "qt_fs_path_exists",
    -- spec 023 T019/T020 — QProcess + QLocalSocket FFI for Resolve bridge.
    "qt_process_create",
    "qt_process_start",
    "qt_process_wait_for_started",
    "qt_process_state",
    "qt_process_terminate",
    "qt_process_kill",
    "qt_process_write",
    "qt_process_pid",
    "qt_process_set_finished_cb",
    "qt_process_set_stdout_cb",
    "qt_process_set_stderr_cb",
    "qt_process_set_error_cb",
    "qt_process_destroy",
    "qt_local_socket_create",
    "qt_local_socket_connect",
    "qt_local_socket_wait_for_connected",
    "qt_local_socket_state",
    "qt_local_socket_write",
    "qt_local_socket_read_all",
    "qt_local_socket_flush",
    "qt_local_socket_close",
    "qt_local_socket_set_connected_cb",
    "qt_local_socket_set_ready_read_cb",
    "qt_local_socket_set_disconnected_cb",
    "qt_local_socket_set_error_cb",
    "qt_local_socket_destroy",
    "qt_set_widget_attribute",
    "qt_update_widget",
    "qt_set_widget_stylesheet",
    "qt_set_widget_property",
    "qt_set_widget_contents_margins",
    "qt_set_object_name",
    "qt_set_focus_handler",
    "qt_set_focus_policy",
    "qt_set_splitter_moved_handler",
    "qt_set_splitter_drag_handler",
    "qt_set_scroll_area_v_scroll_handler",
    "qt_hide_splitter_handle",
    "qt_set_scroll_area_anchor_bottom",
    "qt_suspend_scroll_area_anchor",
    "qt_get_splitter_handle",
    "qt_set_scroll_position",
    "qt_set_scroll_area_scroll_handler",
    "qt_set_widget_cursor",
    "qt_create_single_shot_timer",
    "qt_set_global_key_handler",
    "qt_set_layout_stretch_factor",
    "qt_show_dialog",
    "qt_monotonic_s",
    "qt_file_stat_batch",
    "qt_file_mtime",
    "qt_fs_mkdir_p",
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
    "tests/smoke/**",       -- Python runner (spec 020 Phase 1)
    "**/autogen/**/deps",   -- CMake-generated depfiles under autogen test bundles
    "**/*.py",
    "**/*.pyc",
    "**/__pycache__/**",
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
    "**/*.bak",              -- editor/session backups, never source
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
    ["src/lua/tinytoml.lua"] = {
        -- Third-party TOML parser (vendored) - suppress all warnings
        ignore = { "211", "212", "213", "311", "312", "411", "421", "431", "581" },
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
