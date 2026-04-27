#!/usr/bin/env luajit
-- Regression: Split menu action must handle Rational clip fields (timeline_start/duration) and not crash when start_value is nil.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Minimal Qt stubs required by menu_system at load time
_G.qt_constants = {
    MENU = {
        GET_MENU_BAR = function() end,
        CREATE_MENU = function() end,
        ADD_MENU_TO_BAR = function() end,
        ADD_SUBMENU = function() end,
        CREATE_MENU_ACTION = function() end,
        CONNECT_MENU_ACTION = function() end,
        ADD_MENU_SEPARATOR = function() end,
        SET_ACTION_ENABLED = function() end,
        SET_ACTION_CHECKED = function() end,
    },
    FILE_DIALOG = {
        OPEN_FILE = function() return nil end,
        OPEN_FILES = function() return nil end,
    },
    WIDGET = {
        CREATE = function() end,
        SET_PARENT = function() end,
    },
    PROPERTIES = {
        SET_GEOMETRY = function() end,
        GET_SIZE = function() return 0, 0 end,
        GET_GEOMETRY = function() return true, 0, 0, 0, 0 end,
    },
    DISPLAY = {
        SET_VISIBLE = function() end,
        RAISE = function() end,
    },
}

-- Stub LuaExpat dependency used by menu_system parsing logic (menus aren't parsed in this test).
package.loaded["lxp"] = {
    new = function()
        return {
            parse = function() return true end,
            close = function() end,
        }
    end
}

-- Stub keyboard shortcut modules to avoid pulling full UI stack.
package.loaded["core.keyboard_shortcuts"] = {
    clear_zoom_toggle = function() end,
    toggle_zoom_fit = function() return true end,
    perform_delete_action = function() return false end,
}
package.loaded["core.keyboard_shortcut_registry"] = {
    handle_key_event = function() return false end,
}

-- Minimal profile_scope stub for menu_system listener wrapping.
package.loaded["core.profile_scope"] = {
    wrap = function(_, fn) return fn end
}

-- Clipboard actions stub (not used in this test).
package.loaded["core.clipboard_actions"] = {
    copy = function() return false end,
    paste = function() return false end,
}

local menu_system = require("core.menu_system")
local timeline_state = require("ui.timeline.timeline_state")
local data = require("ui.timeline.state.timeline_state_data")
-- Seed timeline state with a single clip and playhead inside it.
timeline_state.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.project_id = "test_project"
data.state.sequence_id = "timeline_seq"

local clip = {
    id = "clip_rational",
    track_id = "v1",
    timeline_start = 0,
    duration = 48,
    source_in = 0,
    source_out = 48,
    enabled = true,
    -- start_value intentionally absent to mirror UI clip objects
}
data.state.clips = { clip }
data.state.selected_clips = { clip }
timeline_state.set_playhead_position(10)  -- integer frames

local captured_command = nil
local function capture_cmd(cmd)
    captured_command = cmd
    return { success = true }
end
local mock_command_manager = {
    execute = capture_cmd,
    execute_interactive = capture_cmd,
    add_listener = function() end,
    remove_listener = function() end,
    can_undo = function() return false end,
    can_redo = function() return false end,
}

menu_system.init(nil, mock_command_manager, nil)
menu_system.set_timeline_panel({
    get_state = function() return timeline_state end,
})

local callback = menu_system._test_get_action_callback("SplitClip")

local ok, err = pcall(callback)
assert(ok, "SplitClip menu callback errored: " .. tostring(err))
assert(captured_command, "SplitClip menu did not dispatch a command")

assert(type(captured_command) == "string", "Expected SplitClip command string, got " .. type(captured_command))
assert(captured_command == "SplitClip", "Expected SplitClip command, got " .. tostring(captured_command))
print("✅ Split menu handles Rational clip fields and dispatches SplitClip command")
