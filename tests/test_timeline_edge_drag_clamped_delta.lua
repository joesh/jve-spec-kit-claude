#!/usr/bin/env luajit

require("test_env")

local timeline_view_drag_handler = require("ui.timeline.view.timeline_view_drag_handler")
local command_manager = require("core.command_manager")
local Rational = require("core.rational")

_G.timeline = {
    get_dimensions = function() return 1000, 200 end
}

local captured_cmd = nil
local original_execute = command_manager.execute
command_manager.execute = function(cmd)
    captured_cmd = cmd
    return {success = true}
end

local state = {
    get_sequence_id = function() return "seq" end,
    get_project_id = function() return "proj" end,
    get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end,
    get_clip_by_id = function() return {track_id = "track_v1"} end
}

local view = {
    widget = {},
    state = state,
    get_track_id_at_y = function() return "track_v1" end
}

local drag_state = {
    type = "edges",
    current_y = 10,
    start_y = 0,
    edges = {
        {clip_id = "clip_a", edge_type = "gap_before", trim_type = "ripple"}
    },
    lead_edge = {clip_id = "clip_a", edge_type = "gap_before", trim_type = "ripple"},
    delta_rational = Rational.new(100, 24, 1),
    preview_clamped_delta = Rational.new(60, 24, 1),
    preloaded_clip_snapshot = {clip_track_lookup = {clip_a = "track_v1"}},
    timeline_active_region = {interaction_start_frames = 0, interaction_end_frames = 100}
}

timeline_view_drag_handler.handle_release(view, drag_state, nil)

command_manager.execute = original_execute

assert(captured_cmd, "Expected drag handler to execute BatchRippleEdit")
local delta_frames = captured_cmd:get_parameter("delta_frames")
assert(delta_frames == 60,
    string.format("Expected clamped delta_frames 60, got %s", tostring(delta_frames)))

print("✅ Edge drag uses preview clamped delta when executing")
