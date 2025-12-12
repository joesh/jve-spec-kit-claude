#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_timeline_gap_only_preview.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local clips = layout.clips
local tracks = layout.tracks

-- Remove upstream clip so only the downstream clip remains (gap before clip)
local upstream = Clip.load(clips.v1_left.id, layout.db)
assert(upstream:delete(layout.db), "failed to remove upstream clip")

layout:init_timeline_state()

local width, height = 1600, 320
local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 150}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 150}
        }
    },
    debug_id = "gap-only-preview"
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

local function rat(frames)
    return Rational.new(frames, 1000, 1)
end

local gap_edge = {clip_id = clips.v1_right.id, edge_type = "gap_before", track_id = tracks.v1.id, trim_type = "ripple"}
view.drag_state = {
    type = "edges",
    edges = {gap_edge},
    lead_edge = gap_edge,
    delta_rational = rat(-200)
}

timeline_state.set_edge_selection({gap_edge})

local original_timeline = timeline
local rects = {}
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() rects = {} end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(rects, {x = x, y = y, w = w, h = h, color = color})
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

assert(ok, "Renderer threw error: " .. tostring(err))
local preview = view.drag_state.preview_data or {}
assert(#(preview.affected_clips or {}) == 1,
    "Clip should appear in affected_clips when dragging its edge")
local shift_entry = nil
for _, entry in ipairs(preview.shifted_clips or {}) do
    if entry.clip_id == clips.v1_right.id then
        shift_entry = entry
        break
    end
end
assert(shift_entry, "Single-clip ripple should preview the clip's new position")
local expected_start = clips.v1_right.timeline_start + view.drag_state.delta_rational.frames
assert(shift_entry.new_start_value.frames == expected_start,
    string.format("Expected preview shift to %d, got %s",
        expected_start, tostring(shift_entry.new_start_value.frames)))
assert(#rects > 0, "Expected preview rectangles to be drawn")
print("✅ Single clip with leading gap receives a preview outline when trimmed")
