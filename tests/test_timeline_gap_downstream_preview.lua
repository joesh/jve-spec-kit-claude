#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_timeline_gap_downstream_preview.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left = {timeline_start = 0, duration = 1000},
        v1_right = {timeline_start = 1600, duration = 1000},
        v2 = {timeline_start = 1200, duration = 1200}
    }
})
local clips = layout.clips
local tracks = layout.tracks

-- Insert a downstream clip on V2 before initializing the timeline state
local downstream = Clip.create("V2 Downstream", clips.v2.media_id, {
    project_id = layout.project_id,
    owner_sequence_id = layout.sequence_id,
    track_id = tracks.v2.id,
    timeline_start = Rational.new(2600, 1000, 1),
    duration = Rational.new(600, 1000, 1),
    source_in = Rational.new(0, 1000, 1),
    source_out = Rational.new(600, 1000, 1)
})
assert(downstream:save(layout.db), "Failed to insert downstream clip")

layout:init_timeline_state()

downstream = Clip.load(downstream.id, layout.db)
assert(downstream, "Downstream clip should exist")

local width, height = 1800, 360
local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 160},
            [2] = {y = 170, height = 160}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 160},
            [tracks.v2.id] = {y = 170, height = 160}
        }
    },
    debug_id = "gap-downstream-preview"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(y)
    return y < 160 and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local function rat(frames)
    return Rational.new(frames, 1000, 1)
end

local gap_edge = {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"}
local clip_edge = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}

view.drag_state = {
    type = "edges",
    edges = {gap_edge, clip_edge},
    lead_edge = gap_edge,
    delta_rational = rat(-200)
}

timeline_state.set_edge_selection({gap_edge, clip_edge})

local original_timeline = timeline
local drawn_rects = {}
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

local ok, err = pcall(function()
    timeline_renderer.render(view)
end)

timeline = original_timeline
layout:cleanup()

assert(ok, "Timeline renderer errored: " .. tostring(err))
local preview = view.drag_state.preview_data or {}
local shifted = preview.shifted_clips or {}
local found_downstream = false
for _, entry in ipairs(shifted) do
    if entry.clip_id == downstream.id then
        found_downstream = true
        break
    end
end
assert(found_downstream,
    string.format("Downstream clip %s should be highlighted in preview", tostring(downstream.id)))

print("✅ Downstream clips shift preview when gaps ripple across tracks")
