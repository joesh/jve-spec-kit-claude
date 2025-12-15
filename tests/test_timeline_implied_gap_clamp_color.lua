#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_implied_gap_clamp_color.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v2_blocker", "v2_shift", "v1_right"},
        v1_right = {timeline_start = 4200, duration = 1200},
        v2_blocker = {id = "clip_v2_blocker", track_key = "v2", timeline_start = 3600, duration = 400},
        v2_shift = {id = "clip_v2_shift", track_key = "v2", timeline_start = 4400, duration = 800}
    }
})

local tracks = layout.tracks
local clips = layout.clips

layout:init_timeline_state()

local width, height = 1500, 300
local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 140},
            [2] = {y = 150, height = 140}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 140},
            [tracks.v2.id] = {y = 150, height = 140}
        }
    },
    debug_id = "implied-gap-clamp"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(y)
    return y < 140 and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local drawn_rects = {}
local original_timeline = timeline
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() drawn_rects = {} end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(drawn_rects, {x = x, y = y, w = w, h = h, color = color})
    end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local function rat(frames)
    return Rational.new(frames, 1000, 1)
end

local gap_edge = {
    clip_id = clips.v1_right.id,
    edge_type = "gap_before",
    track_id = tracks.v1.id,
    trim_type = "ripple"
}

local function count_track_colors(track_id, color)
    local entry = view.track_layout_cache.by_id[track_id]
    local count = 0
    for _, rect in ipairs(drawn_rects) do
        if rect.y >= entry.y and rect.y <= entry.y + entry.height and rect.color == color then
            count = count + 1
        end
    end
    return count
end

view.drag_state = {
    type = "edges",
    edges = {gap_edge},
    lead_edge = gap_edge,
    delta_rational = rat(-1500)
}
view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)

timeline_state.set_edge_selection({gap_edge})
timeline_renderer.render(view)

local limit_color = timeline_state.colors.edge_selected_limit or "#ff0000"
local avail_color = timeline_state.colors.edge_selected_available or "#00ff00"

assert((view.drag_state.clamped_edges or {})[string.format("%s:%s", clips.v2_shift.id, "gap_before")],
    "Dry run should attribute clamp to the implied downstream gap edge")

local dragged_limit = count_track_colors(tracks.v1.id, limit_color)
assert(dragged_limit == 0,
    "Dragged edge should stay available; implied edge on another track must signal the clamp")

local implied_limit = count_track_colors(tracks.v2.id, limit_color)
assert(implied_limit > 0,
    "Implied downstream gap should render in the limit color when it halts the ripple")

local implied_available = count_track_colors(tracks.v2.id, avail_color)
assert(implied_available == 0,
    "Blocking implied gap should not also draw an available-colored handle")

timeline = original_timeline
layout:cleanup()
print("✅ Implied gap clamps color only the blocking edge")
