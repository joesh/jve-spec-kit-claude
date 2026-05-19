#!/usr/bin/env luajit

-- Regression: dragging a multi-clip selection between tracks should issue MoveClipToTrack for each clip (BatchCommand).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local test_env = require("test_env")

_G.timeline = {
    get_dimensions = function() return 1000, 1000 end
}

local _, executed = test_env.mock_command_manager()

local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")

local state = {
    get_sequence_id = function() return "seq" end,
    get_project_id = function() return "proj" end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_all_tracks = function()
        return {
            {id = "v1", track_type = "VIDEO"},
            {id = "v2", track_type = "VIDEO"},
        }
    end,
    get_clips = function()
        return {
            {id = "c1", track_id = "v1", sequence_start = 0, duration = 48},
            {id = "c2", track_id = "v1", sequence_start = 60, duration = 48},
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
        {id = "c1"},
        {id = "c2"},
    },
    anchor_clip_id = "c1",
    delta_ms = 0,
    delta_frames = 0,
    current_y = 10,
    start_y = 0
}

drag_handler.handle_release(view, drag_state, {})

assert(#executed == 2, "Expected 2 MoveClipToTrack commands")
local seen = {}
for _, cmd in ipairs(executed) do
    assert(cmd.type == "MoveClipToTrack", "Expected MoveClipToTrack, got " .. tostring(cmd.type))
    assert(cmd.params.target_track_id == "v2", "Target track must be v2")
    seen[cmd.params.clip_id] = true
end
assert(seen["c1"] and seen["c2"], "Both clips should be moved")

print("✅ Multi-clip cross-track drag emits MoveClipToTrack commands")
