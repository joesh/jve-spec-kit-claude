#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local edge_utils = require("ui.timeline.edge_utils")
local TimelineActiveRegion = require("core.timeline_active_region")
local color_utils = require("ui.color_utils")

local function sign(value)
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

local TEST_DB = "/tmp/jve/test_timeline_implied_edge_preview.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local clips = layout.clips
local tracks = layout.tracks

layout:init_timeline_state()

local v2_clip = Clip.load(clips.v2.id, layout.db)
assert(v2_clip, "Expected V2 clip to exist for implied edge preview test")

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
    debug_id = "implied-edge-preview"
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

local function build_shift_payload(shift_frames, clamp_map)
    local new_start = v2_clip.timeline_start + Rational.new(shift_frames, v2_clip.timeline_start.fps_numerator, v2_clip.timeline_start.fps_denominator)
    return {
        affected_clips = {},
        shifted_clips = {{
            clip_id = clips.v2.id,
            new_start_value = new_start,
            new_duration = v2_clip.duration
        }},
        clamped_edges = clamp_map or {}
    }
end

local gap_edge = {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"}

local function count_track_rects(rects, track_id, color)
    local entry = view.track_layout_cache.by_id[track_id]
    local count = 0
    for _, rect in ipairs(rects) do
        if rect.color == color and rect.y >= entry.y and rect.y <= entry.y + entry.height then
            count = count + 1
        end
    end
    return count
end

local function render_with_payload(payload, clamped_ms)
    view.drag_state = {
        type = "edges",
        edges = {gap_edge},
        lead_edge = gap_edge,
        delta_rational = Rational.new(-200, 1000, 1)
    }
    view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 200})
    view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)
    timeline_state.set_edge_selection({gap_edge})

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

    local original_get_executor = command_manager.get_executor
    command_manager.get_executor = function(name)
        if name == "BatchRippleEdit" then
            return function(cmd)
                cmd:set_parameter("clamped_delta_ms", clamped_ms or -200)
                return true, payload
            end
        end
        return original_get_executor(name)
    end

    local ok, err = pcall(function()
        timeline_renderer.render(view)
    end)

    command_manager.get_executor = original_get_executor
    timeline = original_timeline

    assert(ok, "timeline renderer errored: " .. tostring(err))
    return drawn_rects, view.drag_state.preview_data
end

local available_color = timeline_state.colors.edge_selected_available or "#00ff00"
local limit_color = timeline_state.colors.edge_selected_limit or "#ff0000"
local implied_dim_factor = 0.55
local implied_available_color = color_utils.dim_hex(available_color, implied_dim_factor)
local implied_limit_color = color_utils.dim_hex(limit_color, implied_dim_factor)

local shift_frames = 200
local drawn, preview_payload = render_with_payload(build_shift_payload(shift_frames))
assert(preview_payload and preview_payload.shifted_clips and #preview_payload.shifted_clips > 0,
    "Stub payload should expose shifted clips for implied edge rendering")
local implied_meta = preview_payload.implied_edges or {}
assert(#implied_meta > 0, "Preview payload should expose implied edges metadata")
local expected_bracket = edge_utils.to_bracket(gap_edge.edge_type)
local global_sign = sign(view.drag_state.delta_rational.frames)
local shift_sign = sign(shift_frames)
if shift_sign ~= 0 and global_sign ~= 0 and shift_sign ~= global_sign then
    expected_bracket = (expected_bracket == "in") and "out" or "in"
end
for _, edge in ipairs(implied_meta) do
    local expected_raw = (expected_bracket == "in") and "gap_after" or "gap_before"
    assert(edge.raw_edge_type == expected_raw,
        string.format("Implied edge should use gap geometry; got %s", tostring(edge.raw_edge_type)))
    assert(edge.edge_type == expected_bracket,
        string.format("Implied edge should match lead bracket %s (got %s)", tostring(expected_bracket), tostring(edge.edge_type)))
    assert(edge.delta and edge.delta.frames == shift_frames,
        string.format("Implied edge delta should equal shift (%d), got %s", shift_frames, tostring(edge.delta and edge.delta.frames)))
end
local implied_available = count_track_rects(drawn, tracks.v2.id, implied_available_color)
assert(implied_available > 0,
    "Tracks shifted by ripple should render implied handles in a dimmed available color")

local clamp_key = string.format("%s:%s", clips.v2.id, "gap_before")
local drawn_clamped = select(1, render_with_payload(build_shift_payload(200, {[clamp_key] = true})))
local implied_limit = count_track_rects(drawn_clamped, tracks.v2.id, implied_limit_color)
assert(implied_limit > 0,
    "Implied handles should switch to a dimmed limit color when their edge clamps movement")

layout:cleanup()
print("✅ Implied ripple edges render during drag previews")
