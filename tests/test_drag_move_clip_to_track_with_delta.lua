#!/usr/bin/env luajit

-- Regression: cross-track drag with a time delta uses MoveClipToTrack carrying pending_new_start (no extra Nudge).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local test_env = require("test_env")

require("dkjson")

_G.timeline = {
    get_dimensions = function() return 1000, 1000 end
}

local _, executed = test_env.mock_command_manager()

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
            {id = "clip1", track_id = "v1", timeline_start = 0, duration = 24}
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
    delta_ms = 1000,
    delta_frames = 24,
    current_y = 10,
    start_y = 0
}

local drag_handler = require("ui.timeline.view.timeline_view_drag_handler")
drag_handler.handle_release(view, drag_state, {})

assert(#executed == 1, "Expected one command to execute (MoveClipToTrack)")
local cmd = executed[1]
assert(cmd.type == "MoveClipToTrack", "Expected MoveClipToTrack, got " .. tostring(cmd.type))
assert(cmd.params.target_track_id == "v2", "Move target should be v2")
assert(cmd.params.pending_new_start == 24, "Move should carry pending start with full delta")
assert(cmd.params.pending_clips and cmd.params.pending_clips["clip1"], "pending_clips should include moving clip for occlusion avoidance")

print("✅ Cross-track drag with delta keeps time via MoveClipToTrack pending_new_start")
