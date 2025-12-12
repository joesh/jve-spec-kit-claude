#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")

local TEST_DB = "/tmp/jve/test_timeline_edge_limit_unselected.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left = {timeline_start = 0, duration = 1000},
        v1_right = {timeline_start = 3000, duration = 500},
        v2 = {timeline_start = 1500, duration = 800}
    }
})

local clips = layout.clips
local tracks = layout.tracks
layout:init_timeline_state()

local width, height = 2000, 400
local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {
        {id = tracks.v1.id},
        {id = tracks.v2.id}
    },
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 180},
            [2] = {y = 200, height = 180}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 180, track_type = "VIDEO"},
            [tracks.v2.id] = {y = 200, height = 180, track_type = "VIDEO"}
        }
    },
    debug_id = "edge-limit-unselected"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(y)
    if y < 180 then return tracks.v1.id end
    return tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local drawn_rects = {}
local original_timeline = timeline
_G.timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() drawn_rects = {} end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(drawn_rects, {x = x, y = y, w = w, h = h, color = color})
    end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local original_get_executor = command_manager.get_executor
command_manager.get_executor = function(name)
    if name == "BatchRippleEdit" then
        return function(cmd)
            cmd:set_parameter("clamped_delta_ms", 0)
            return true, {
                affected_clips = {},
                shifted_clips = {},
                clamped_edges = {
                    [string.format("%s:%s", clips.v1_right.id, "in")] = true
                }
            }
        end
    end
    return original_get_executor(name)
end

local v2_edge = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
view.drag_state = {
    type = "edges",
    edges = {v2_edge},
    lead_edge = v2_edge,
    delta_rational = Rational.new(200, 1000, 1)
}
timeline_state.set_edge_selection({v2_edge})

local ok, err = pcall(function()
    timeline_renderer.render(view)
end)

command_manager.get_executor = original_get_executor
_G.timeline = original_timeline
layout:cleanup()

assert(ok, "timeline renderer errored: " .. tostring(err))

local limit_color = timeline_state.colors.edge_selected_limit or "#ff0000"
local function count_limit_rects_for_track(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    local count = 0
    for _, rect in ipairs(drawn_rects) do
        if rect.y >= entry.y and rect.y <= entry.y + entry.height and rect.color == limit_color then
            count = count + 1
        end
    end
    return count
end

local v1_limit_rects = count_limit_rects_for_track(tracks.v1.id)
assert(v1_limit_rects > 0,
    "Renderer should draw limit-colored bracket for clamped edge even when it is not selected")

print("✅ Edge preview renders unselected clamp edges using the limit color")
