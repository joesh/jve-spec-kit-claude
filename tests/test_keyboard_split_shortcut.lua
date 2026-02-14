#!/usr/bin/env luajit
-- Regression: Cmd/Ctrl+B (Blade/Split) should dispatch Blade command via TOML keybindings.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local keyboard_shortcuts = require("core.keyboard_shortcuts")
local timeline_state = require("ui.timeline.timeline_state")
local data = require("ui.timeline.state.timeline_state_data")

-- Focus panel needs to be "timeline" for the shortcut to be active.
local focus_manager = require("ui.focus_manager")
focus_manager.get_focused_panel = function() return "timeline" end

-- Prepare timeline state
timeline_state.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.project_id = "test_project"
data.state.sequence_id = "timeline_seq"
local clip = {
    id = "clip_under_playhead",
    track_id = "v1",
    name = "Clip 1",
    timeline_start = 0,
    duration = 48,
    source_in = 0,
    source_out = 48,
    enabled = true,
}
data.state.clips = { clip }
data.state.selected_clips = { clip }
timeline_state.set_playhead_position(10)

-- Stub command manager with execute_ui + get_executor for TOML dispatch
local captured_commands = {}
local mock_command_manager = {
    execute_ui = function(command_name, params)
        captured_commands[#captured_commands + 1] = {
            name = command_name,
            params = params or {},
        }
        return { success = true }
    end,
    get_executor = function(command_name)
        -- Return a dummy for Blade so TOML dispatch works
        if command_name == "Blade" then return function() end end
        return nil
    end,
    peek_command_event_origin = function() return nil end,
    begin_command_event = function() end,
    end_command_event = function() end,
}

keyboard_shortcuts.init(timeline_state, mock_command_manager, nil, nil)

local event = {
    key = keyboard_shortcuts.KEY.B,
    modifiers = keyboard_shortcuts.MOD.Meta,
    text = "b",
    focus_widget_is_text_input = 0,
}

local ok, err = pcall(function()
    return keyboard_shortcuts.handle_key(event)
end)

assert(ok, "keyboard_shortcuts.handle_key errored: " .. tostring(err))
assert(#captured_commands > 0, "Blade command was not dispatched")
assert(captured_commands[1].name == "Blade",
    "Expected Blade command, got: " .. tostring(captured_commands[1].name))

print("✅ Cmd/Ctrl+B dispatches Blade command via TOML keybindings")
