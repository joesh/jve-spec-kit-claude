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
local Rational = require("core.rational")
local dkjson = require("dkjson")

-- Seed timeline state with a single clip and playhead inside it.
timeline_state.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }

local clip = {
    id = "clip_rational",
    track_id = "v1",
    timeline_start = Rational.new(0, 24, 1),
    duration = Rational.new(48, 24, 1),
    source_in = Rational.new(0, 24, 1),
    source_out = Rational.new(48, 24, 1),
    enabled = true,
    -- start_value intentionally absent to mirror UI clip objects
}
data.state.clips = { clip }
data.state.selected_clips = { clip }
timeline_state.set_playhead_position(Rational.new(10, 24, 1))

local captured_command = nil
local mock_command_manager = {
    execute = function(cmd)
        captured_command = cmd
        return { success = true }
    end,
    add_listener = function() end,
    remove_listener = function() end,
    can_undo = function() return false end,
    can_redo = function() return false end,
}

menu_system.init(nil, mock_command_manager, nil)
menu_system.set_timeline_panel({
    get_state = function() return timeline_state end,
})

local callback = menu_system._test_get_action_callback("Split")

local ok, err = pcall(callback)
assert(ok, "Split menu callback errored: " .. tostring(err))
assert(captured_command, "Split menu did not dispatch a command")
assert(captured_command.type == "BatchCommand", "Expected BatchCommand, got " .. tostring(captured_command.type))

local payload = captured_command:get_parameter("commands_json")
assert(payload, "BatchCommand missing commands_json")
local specs = dkjson.decode(payload)
assert(type(specs) == "table" and #specs == 1, "Expected one SplitClip spec")
assert(specs[1].command_type == "SplitClip", "Expected SplitClip command")
assert(specs[1].parameters.clip_id == clip.id, "SplitClip target clip mismatch")

print("✅ Split menu handles Rational clip fields and dispatches without crash")
