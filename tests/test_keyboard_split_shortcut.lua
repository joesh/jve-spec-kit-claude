#!/usr/bin/env luajit
-- Regression: Cmd/Ctrl+B (Blade/Split) should dispatch a BatchCommand to SplitClip without errors.
-- Current bug: timeline_state lacks get_clips_at_time, causing "attempt to call nil value" during shortcut handling.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local keyboard_shortcuts = require("core.keyboard_shortcuts")
local timeline_state = require("ui.timeline.timeline_state")
local data = require("ui.timeline.state.timeline_state_data")
local dkjson = require("dkjson")
local Command = require("command")

-- Focus panel needs to be "timeline" for the shortcut to be active.
local focus_manager = require("ui.focus_manager")
focus_manager.get_focused_panel = function() return "timeline" end

-- Prepare a clip under the playhead.
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

-- Stub command manager to capture the dispatched command.
local captured_command = nil
local mock_command_manager = {
    execute = function(command_or_name, params)
        if type(command_or_name) == "table" then
            captured_command = command_or_name
        else
            -- Create a proper Command object so the test can call :get_parameter()
            captured_command = Command.create(command_or_name, params.project_id or "test_project", params)
        end
        return { success = true }
    end
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
assert(captured_command, "BatchCommand was not dispatched")
assert(captured_command.type == "BatchCommand", "Expected BatchCommand, got " .. tostring(captured_command.type))

local payload = captured_command:get_parameter("commands_json")
assert(payload, "commands_json missing from dispatched BatchCommand")
local specs = dkjson.decode(payload)
assert(type(specs) == "table" and #specs == 1, "Expected one SplitClip spec, got " .. tostring(specs and #specs))
assert(specs[0] == nil, "commands_json should be an array")
assert(specs[1].command_type == "SplitClip", "Expected SplitClip command, got " .. tostring(specs[1].command_type))
assert(specs[1].parameters.clip_id == clip.id, "SplitClip target clip mismatch")

print("✅ Cmd/Ctrl+B dispatched SplitClip BatchCommand without errors")
