#!/usr/bin/env luajit

require("test_env")

local timeline_state = require("ui.timeline.timeline_state")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")
local TimelineActiveRegion = require("core.timeline_active_region")
local color_utils = require("ui.color_utils")

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
            local limiter_key = string.format("%s:%s", clips.v1_right.id, "in")
            return true, {
                affected_clips = {},
                shifted_clips = {},
                clamped_edges = {
                    [limiter_key] = true
                },
                edge_preview = {
                    requested_delta_frames = 200,
                    clamped_delta_frames = 0,
                    limiter_edge_keys = {[limiter_key] = true},
                    edges = {{
                        edge_key = limiter_key,
                        clip_id = clips.v1_right.id,
                        track_id = tracks.v1.id,
                        raw_edge_type = "in",
                        normalized_edge = "in",
                        is_selected = false,
                        is_implied = true,
                        is_limiter = true,
                        applied_delta_frames = 0
                    }}
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
    delta_frames = 200
}
view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)
timeline_state.set_edge_selection({v2_edge})

local ok, err = pcall(function()
    timeline_renderer.render(view)
end)

command_manager.get_executor = original_get_executor
_G.timeline = original_timeline
layout:cleanup()

assert(ok, "timeline renderer errored: " .. tostring(err))

local limit_color = timeline_state.colors.edge_selected_limit or "#ff0000"
local implied_dim_factor = 0.55
local implied_limit_color = color_utils.dim_hex(limit_color, implied_dim_factor)
local function count_limit_rects_for_track(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    local count = 0
    for _, rect in ipairs(drawn_rects) do
        if rect.y >= entry.y and rect.y <= entry.y + entry.height and rect.color == implied_limit_color then
            count = count + 1
        end
    end
    return count
end

local v1_limit_rects = count_limit_rects_for_track(tracks.v1.id)
assert(v1_limit_rects > 0,
    "Renderer should draw dimmed limit-colored bracket for clamped edge even when it is not selected")

print("✅ Edge preview renders unselected clamp edges using a dimmed limit color")
