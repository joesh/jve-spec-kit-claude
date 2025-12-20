#!/usr/bin/env luajit

-- Regression: dragging a vertical stack of clips between tracks must move higher tracks first
-- so MoveClipToTrack operations don't fail due to transient occlusions.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local Rational = require("core.rational")
local json = require("dkjson")

_G.timeline = {
    get_dimensions = function() return 1000, 1000 end
}

local executed = {}
package.loaded["core.command_manager"] = {
    execute = function(cmd)
        table.insert(executed, cmd)
        return {success = true}
    end
}

local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")

local state = {
    get_sequence_id = function() return "seq" end,
    get_project_id = function() return "proj" end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_all_tracks = function()
        return {
            {id = "v1", track_type = "VIDEO"},
            {id = "v2", track_type = "VIDEO"},
            {id = "v3", track_type = "VIDEO"}
        }
    end,
    get_clips = function()
        return {
            {id = "clip_low", track_id = "v1", timeline_start = Rational.new(0,24,1), duration = Rational.new(48,24,1)},
            {id = "clip_high", track_id = "v2", timeline_start = Rational.new(0,24,1), duration = Rational.new(48,24,1)}
        }
    end
}

local view = {
    state = state,
    widget = {},
    get_track_id_at_y = function()
        return "v2" -- anchor clip on v1 moves to v2 => track_offset = +1
    end
}

local drag_state = {
    type = "clips",
    clips = {
        {id = "clip_low"},
        {id = "clip_high"},
    },
    anchor_clip_id = "clip_low",
    delta_ms = 0,
    delta_rational = Rational.new(0, 24, 1),
    current_y = 10,
    start_y = 0
}

drag_handler.handle_release(view, drag_state, {})

assert(#executed == 1, "Expected BatchCommand execution")
local batch = executed[1]
assert(batch.type == "BatchCommand", "Drag should execute BatchCommand")
local specs = json.decode(batch:get_parameter("commands_json"))
assert(#specs == 2, "Expected two MoveClipToTrack commands")

local first = specs[1]
local second = specs[2]
assert(first.parameters.clip_id == "clip_high",
    string.format("Clip on higher track should move first; got %s", tostring(first.parameters.clip_id)))
assert(first.parameters.target_track_id == "v3",
    string.format("clip_high should move to v3; got %s", tostring(first.parameters.target_track_id)))
assert(second.parameters.clip_id == "clip_low",
    string.format("clip_low should move second; got %s", tostring(second.parameters.clip_id)))
assert(second.parameters.target_track_id == "v2",
    string.format("clip_low should move into v2; got %s", tostring(second.parameters.target_track_id)))

print("✅ Vertical stack drag orders MoveClipToTrack commands by track index")
