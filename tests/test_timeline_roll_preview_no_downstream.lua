#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_roll_preview_no_downstream.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left = {timeline_start = 0, duration = 1000},
        v1_right = {timeline_start = 2000, duration = 1000},
        v1_downstream = {timeline_start = 3600, duration = 800}
    }
})

local clips = layout.clips
local tracks = layout.tracks
layout:init_timeline_state()

local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 180}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 180}
        }
    },
    debug_id = "roll-preview-no-downstream"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(_)
    return tracks.v1.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local gap_edge = {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "roll"}
local clip_edge = {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"}
view.drag_state = {
    type = "edges",
    edges = {gap_edge, clip_edge},
    lead_edge = clip_edge,
    delta_rational = Rational.new(-200, 1000, 1)
}

timeline_state.set_edge_selection({gap_edge, clip_edge})

local viewport_width, viewport_height = 2000, 240

local original_timeline = timeline
local highlight_rects = {}
_G.timeline = {
    get_dimensions = function() return viewport_width, viewport_height end,
    clear_commands = function() highlight_rects = {} end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(highlight_rects, {x = x, y = y, w = w, h = h, color = color})
    end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local ok, err = pcall(function()
    timeline_renderer.render(view)
end)

_G.timeline = original_timeline
layout:cleanup()

assert(ok, "timeline renderer errored: " .. tostring(err))

local seq_rate = timeline_state.get_sequence_frame_rate()
local function to_rational(frames)
    return Rational.new(frames, seq_rate.fps_numerator, seq_rate.fps_denominator)
end

local downstream_start_px = timeline_state.time_to_pixel(
    to_rational(clips.v1_downstream.timeline_start),
    viewport_width
)
local downstream_highlight = false
for _, rect in ipairs(highlight_rects) do
    if rect.color == "#ffff00" then
        local near_downstream = math.abs(rect.x - downstream_start_px) < 5
        if near_downstream then
            downstream_highlight = true
            break
        end
    end
end

assert(not downstream_highlight, "Roll preview should not highlight downstream ripple clips")

local yellow_count = 0
for _, rect in ipairs(highlight_rects) do
    if rect.color == "#ffff00" then yellow_count = yellow_count + 1 end
end
assert(yellow_count > 0, "Roll preview should highlight the participating edges")

print("✅ Roll preview skips downstream highlight when no ripple shift occurs")
