#!/usr/bin/env luajit

-- Regression: dragging a clip to another track should issue MoveClipToTrack (not just Nudge).

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";../tests/?.lua"

require("test_env")

-- Stub timeline dimensions
_G.timeline = {
    get_dimensions = function() return 1000, 1000 end
}

-- Capture commands executed
local executed = {}
package.loaded["core.command_manager"] = {
    execute = function(cmd)
        table.insert(executed, cmd)
        return {success = true}
    end
}

local Rational = require("core.rational")
local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")
local Command = require("command")

local state = {
    get_sequence_id = function() return "seq" end,
    get_project_id = function() return "proj" end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_all_tracks = function()
        return {
            {id = "v1", track_type = "VIDEO"},
            {id = "v2", track_type = "VIDEO"}
        }
    end,
    get_clips = function()
        return {
            {id = "clip1", track_id = "v1", timeline_start = Rational.new(0,24,1), duration = Rational.new(24,24,1)}
        }
    end
}

local view = {
    state = state,
    widget = {},
    get_track_id_at_y = function(y, h) return "v2" end
}

local drag_state = {
    type = "clips",
    clips = {
        {id = "clip1"}
    },
    delta_ms = 0,
    delta_rational = Rational.new(0,24,1),
    current_y = 10,
    start_y = 0
}

drag_handler.handle_release(view, drag_state, {})

assert(#executed == 1, "Expected one command to execute")
local cmd = executed[1]
assert(cmd.type == "MoveClipToTrack", "Expected MoveClipToTrack, got " .. tostring(cmd.type))
assert(cmd:get_parameter("target_track_id") == "v2", "Move target should be v2")

print("✅ Drag to another track issues MoveClipToTrack")
