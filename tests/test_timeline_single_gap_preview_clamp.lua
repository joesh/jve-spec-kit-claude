#!/usr/bin/env luajit

require("test_env")

local timeline_state = require("ui.timeline.timeline_state")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_single_gap_preview_clamp.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left = {timeline_start = 0, duration = 500},
        v1_right = {timeline_start = 1500, duration = 500},
        v2 = {timeline_start = 2000, duration = 500}
    }
})
local clips = layout.clips
local tracks = layout.tracks

layout:init_timeline_state()

local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 120},
            [2] = {y = 130, height = 120}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 120},
            [tracks.v2.id] = {y = 130, height = 120}
        }
    },
    debug_id = "single-gap-preview-clamp"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(y)
    return y < 120 and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local edge = {clip_id = clips.v2.id, edge_type = "gap_before", track_id = tracks.v2.id, trim_type = "ripple"}
view.drag_state = {
    type = "edges",
    edges = {edge},
    lead_edge = edge,
    delta_frames = -3000
}
view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)

timeline_state.set_edge_selection({edge})

local original_timeline = timeline
local width, height = 1200, 300
_G.timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local ok, err = pcall(function()
    timeline_renderer.render(view)
end)

_G.timeline = original_timeline
layout:cleanup()

assert(ok, "Timeline renderer errored: " .. tostring(err))

local preview = view.drag_state.preview_data or {}
local shifted_lookup = {}
for _, entry in ipairs(preview.shifted_clips or {}) do
    shifted_lookup[entry.clip_id] = entry
end

local clip_shift = shifted_lookup[clips.v2.id]
assert(clip_shift, "Single gap drag preview should report downstream shift for the trailing clip")

local new_start = clip_shift.new_start_value
assert(new_start and new_start == 0,
    string.format("Clamped preview should stop at timeline start (expected 0, got %s)",
        tostring(new_start)))

print("✅ Single-edge gap previews clamp to the available gap before execution")
