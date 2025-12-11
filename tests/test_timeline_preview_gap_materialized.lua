#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

require("test_env")

local Rational = require("core.rational")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_preview_gap_materialized.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local clips = layout.clips
local tracks = layout.tracks

layout:init_timeline_state()

local width, height = 1200, 300

local function build_view()
    return {
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
        debug_id = "preview_gap_materialized"
    }
end

local view = build_view()

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    return view.track_layout_cache.by_id[track_id].height
end
function view.get_track_id_at_y(y)
    return y < 120 and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local function rational(frames)
    return Rational.new(frames, 1000, 1)
end

local gap_start = Rational.new(clips.v1_left.timeline_start + clips.v1_left.duration, 1000, 1)
local gap_end = Rational.new(clips.v1_right.timeline_start, 1000, 1)

local affected_rects = {}
local original_timeline = _G.timeline
_G.timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() affected_rects = {} end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(affected_rects, {x = x, y = y, w = w, h = h, color = color})
    end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local gap_edge = {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"}

view.drag_state = {
    type = "edges",
    edges = {gap_edge},
    lead_edge = gap_edge,
    delta_rational = rational(-200)
}
view.drag_state.preview_request_token = string.format("%s:%s@%d",
    gap_edge.clip_id,
    gap_edge.edge_type,
    view.drag_state.delta_rational.frames)

timeline_state.set_edge_selection({gap_edge})

timeline_renderer.render(view)

local yellow_rects = {}
for _, rect in ipairs(affected_rects) do
    if rect.color == "#ffff00" then
        table.insert(yellow_rects, rect)
    end
end

assert(#yellow_rects > 0, "Expected downstream clips to preview shift")

local gap_start_px = timeline_state.time_to_pixel(gap_start, width)
local gap_end_px = timeline_state.time_to_pixel(gap_end, width)
local gap_width = gap_end_px - gap_start_px

for _, rect in ipairs(yellow_rects) do
    local overlaps_gap = math.abs(rect.x - gap_start_px) <= 2 and math.abs(rect.w - gap_width) <= 2
    assert(not overlaps_gap,
        string.format("Gap preview should not draw yellow box (rect x=%d w=%d, gap x=%d w=%d)",
            rect.x, rect.w, gap_start_px, gap_width))
end

_G.timeline = original_timeline
layout:cleanup()
print("✅ Gap previews skip yellow clip rectangles when only materialized gaps are affected")
