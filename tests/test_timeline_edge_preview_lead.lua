#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local renderer = require("ui.timeline.view.timeline_view_renderer")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_edge_preview_lead.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local tracks = layout.tracks
local clips = layout.clips

layout:init_timeline_state()

local width, height = 1000, 300

local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 120},
            [2] = {y = 140, height = 120}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 120},
            [tracks.v2.id] = {y = 140, height = 120}
        }
    },
    debug_id = "lead-edge-preview-test"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(y)
    return (y < 120) and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local original_timeline = timeline
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local function rational(frames)
    return Rational.new(frames, 1000, 1)
end

local edges = {
    {clip_id = clips.v1_left.id, edge_type = "out", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "in", track_id = tracks.v2.id, trim_type = "ripple"}
}
local lead_edge = edges[2]

view.drag_state = {
    type = "edges",
    edges = edges,
    lead_edge = lead_edge,
    delta_rational = rational(240)
}
view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, edges, {pad_frames = 200})
view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)

timeline_state.set_edge_selection(edges)

local original_get_executor = command_manager.get_executor
local captured_lead = nil
command_manager.get_executor = function(name)
    local executor = original_get_executor(name)
    if not executor then
        return nil
    end
    return function(cmd, ...)
        captured_lead = cmd:get_parameter("lead_edge")
        return executor(cmd, ...)
    end
end

local ok, err = pcall(function()
    renderer.render(view)
end)

command_manager.get_executor = original_get_executor
timeline = original_timeline
layout:cleanup()

assert(ok, "renderer.render should not error: " .. tostring(err))
assert(captured_lead, "renderer should pass lead_edge to preview command")
assert(captured_lead.clip_id == lead_edge.clip_id, "lead edge clip_id should match dragged edge")
assert(captured_lead.edge_type == lead_edge.edge_type, "lead edge type should match dragged edge")

print("✅ Edge preview dry runs respect the dragged lead edge")
