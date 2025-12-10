#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

require("test_env")

local Rational = require("core.rational")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_preview_gap_clamp.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local clips = layout.clips
local tracks = layout.tracks

layout:init_timeline_state()

local width, height = 1200, 300
local track_v1_id = tracks.v1.id
local track_v2_id = tracks.v2.id

local view = {
    widget = {}, state = timeline_state,
    filtered_tracks = {{id = track_v1_id}, {id = track_v2_id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 120},
            [2] = {y = 130, height = 120}
        },
        by_id = {
            [track_v1_id] = {y = 0, height = 120},
            [track_v2_id] = {y = 130, height = 120}
        }
    },
    debug_id = "preview_gap_clamp"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    return view.track_layout_cache.by_id[track_id].height
end
function view.get_track_id_at_y(y)
    return y < 120 and track_v1_id or track_v2_id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local affected_rects = {}
local original_timeline = timeline
_G.timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(affected_rects, {x = x, y = y, w = w, h = h, color = color})
    end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local edges = {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
}

view.drag_state = {
    type = "edges",
    edges = edges,
    lead_edge = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"},
    delta_rational = Rational.new(-800, 1000, 1),
    preview_data = nil
}

timeline_state.set_edge_selection(edges)

affected_rects = {}
timeline_renderer.render(view)

local yellow_rects = {}
for _, rect in ipairs(affected_rects) do
    if rect.color == "#ffff00" then
        table.insert(yellow_rects, rect)
    end
end

assert(#yellow_rects > 0, "Expected yellow preview rects for dragged clips")

local clamp_px = timeline_state.time_to_pixel(Rational.new(1500, 1000, 1), width)

for _, rect in ipairs(yellow_rects) do
    assert(rect.x >= clamp_px,
        string.format("Preview should clamp at %d (rect.x=%d)", clamp_px, rect.x))
end

_G.timeline = original_timeline
layout:cleanup()
print("✅ Preview respects clamp (expected failure before fix)")
