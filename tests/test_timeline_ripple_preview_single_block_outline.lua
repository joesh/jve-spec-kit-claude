#!/usr/bin/env luajit

-- Contract: during a ripple edit drag with downstream movers spanning
-- multiple tracks, the renderer draws ONE bounding outline that
-- encompasses every downstream-shifted clip across all affected tracks.
-- Individual downstream clips (the ones the user is NOT directly
-- dragging) do NOT receive their own per-clip outline.
--
-- The clips whose edges the user is actively dragging keep their
-- per-clip outline — that is the direct gesture-feedback affordance
-- and is unrelated to the downstream block.

require("test_env")

local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local Clip = require("models.clip")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_ripple_preview_single_block_outline.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left  = {sequence_start = 0,    duration = 1000},
        v1_right = {sequence_start = 1600, duration = 1000},
        v2       = {sequence_start = 1200, duration = 1200},
    }
})
local clips, tracks = layout.clips, layout.tracks

-- Downstream V2 clip — a non-active mover that will shift as a
-- consequence of the ripple. Its position after a -200 ripple is
-- sequence_start - 200 = 2400.
local _primary_master = layout.master_seq_for_media[layout.media.main.id]
local v2_downstream_id = Clip.create({
    name = "V2 Downstream",
    project_id = layout.project_id,
    owner_sequence_id = layout.sequence_id,
    sequence_id = _primary_master,
    track_id = tracks.v2.id,
    sequence_start_frame = 2600,
    duration_frames = 600,
    source_in_frame = 0,
    source_out_frame = 600,
    fps_mismatch_policy = "resample",
    volume = 1.0,
    playhead_frame = 0,
    enabled = 1,
})
assert(v2_downstream_id and v2_downstream_id ~= "", "Failed to insert downstream clip")

layout:init_timeline_state()

local v2_downstream = Clip.load(v2_downstream_id)
assert(v2_downstream, "downstream clip must exist after init")

local width, height = 1800, 360
local TRACK_HEIGHT = 160
local V1_Y, V2_Y = 0, 170
local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = V1_Y, height = TRACK_HEIGHT},
            [2] = {y = V2_Y, height = TRACK_HEIGHT},
        },
        by_id = {
            [tracks.v1.id] = {y = V1_Y, height = TRACK_HEIGHT},
            [tracks.v2.id] = {y = V2_Y, height = TRACK_HEIGHT},
        },
    },
    debug_id = "ripple-single-block-outline",
}
function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local e = view.track_layout_cache.by_id[track_id]
    return e and e.height or 0
end
function view.get_track_id_at_y(y)
    return y < TRACK_HEIGHT and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local e = view.track_layout_cache.by_id[track_id]
    return e and e.y or -1
end

-- Drag: ripple the V1 gap's IN edge AND V2's OUT edge by -200 frames.
-- The downstream V2 clip will shift from 2600 to 2400 as a result.
local v1_gap_start = clips.v1_left.sequence_start + clips.v1_left.duration
local v1_gap_id = layout:gap_id("v1", v1_gap_start)
local gap_edge = {clip_id = v1_gap_id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"}
local v2_edge  = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}

view.drag_state = {
    type = "edges",
    edges = {gap_edge, v2_edge},
    lead_edge = gap_edge,
    delta_frames = -200,
}
view.drag_state.timeline_active_region =
    TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot =
    TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)
timeline_state.set_edge_selection({gap_edge, v2_edge})

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
    update = function() end,
}

local ok, err = pcall(function() timeline_renderer.render(view) end)
timeline = original_timeline
assert(ok, "timeline renderer errored: " .. tostring(err))

local PREVIEW_COLOR = "#ffff00"

-- Geometry expectations derived from the fixture, not the renderer.
local v2_downstream_shifted_start = 2400  -- 2600 + (-200)
local v2_downstream_duration      = 600
local downstream_left_px  = timeline_state.time_to_pixel(v2_downstream_shifted_start, width)
local downstream_right_px = timeline_state.time_to_pixel(
    v2_downstream_shifted_start + v2_downstream_duration, width)
local downstream_clip_width_px = downstream_right_px - downstream_left_px
local v2_clip_top_y    = V2_Y + 5
local v2_clip_bottom_y = V2_Y + TRACK_HEIGHT - 10
local v2_clip_height_px = TRACK_HEIGHT - 10

-- Domain assertion 1 (negative): the downstream V2 clip has NO outline of
-- its own. The four edges of a per-clip outline are:
--   top:    (x=left,  y=clip_top,         w=clip_width, h=2)
--   bottom: (x=left,  y=clip_bottom-2,    w=clip_width, h=2)
--   left:   (x=left,  y=clip_top,         w=2,          h=clip_height)
--   right:  (x=right-2, y=clip_top,       w=2,          h=clip_height)
local function approx(a, b) return math.abs(a - b) <= 1 end
local function rect_is_per_clip_side(r)
    if r.color ~= PREVIEW_COLOR then return false end
    local matches_top    = approx(r.x, downstream_left_px) and approx(r.y, v2_clip_top_y)
                       and approx(r.w, downstream_clip_width_px) and approx(r.h, 2)
    local matches_bottom = approx(r.x, downstream_left_px) and approx(r.y, v2_clip_bottom_y - 2)
                       and approx(r.w, downstream_clip_width_px) and approx(r.h, 2)
    local matches_left   = approx(r.x, downstream_left_px) and approx(r.y, v2_clip_top_y)
                       and approx(r.w, 2) and approx(r.h, v2_clip_height_px)
    local matches_right  = approx(r.x, downstream_right_px - 2) and approx(r.y, v2_clip_top_y)
                       and approx(r.w, 2) and approx(r.h, v2_clip_height_px)
    return matches_top or matches_bottom or matches_left or matches_right
end
for _, r in ipairs(drawn_rects) do
    assert(not rect_is_per_clip_side(r),
        string.format("Downstream non-active V2 clip must not have its own outline; "
            .. "found stray side rect at x=%d y=%d w=%d h=%d", r.x, r.y, r.w, r.h))
end

-- Domain assertion 2 (positive): each track with a downstream mover gets
-- its OWN per-track contoured outline (see test_timeline_ripple_preview_
-- contoured_runs). The V2 downstream clip lives in V2's band, so a
-- preview-color rect must exist that's confined to V2's band AND
-- overlaps the clip's shifted x range. The outlines do NOT span tracks
-- (that would create a giant offscreen-dominated bbox on real timelines).
local function approx_within(value, low, high) return value >= low - 1 and value <= high + 1 end
local v2_band_top, v2_band_bottom = V2_Y, V2_Y + TRACK_HEIGHT
local v2_clip_left  = timeline_state.time_to_pixel(v2_downstream_shifted_start, width)
local v2_clip_right = timeline_state.time_to_pixel(
    v2_downstream_shifted_start + v2_downstream_duration, width)
local found_v2_per_track_outline = false
for _, r in ipairs(drawn_rects) do
    if r.color == PREVIEW_COLOR then
        local top, bottom = r.y, r.y + r.h
        local left, right = r.x, r.x + r.w
        local contained_in_v2 = approx_within(top, v2_band_top, v2_band_bottom)
                            and approx_within(bottom, v2_band_top, v2_band_bottom)
        local overlaps_clip_x = left < v2_clip_right and right > v2_clip_left
        if contained_in_v2 and overlaps_clip_x then
            found_v2_per_track_outline = true; break
        end
    end
end
assert(found_v2_per_track_outline,
    "Expected a preview outline confined to V2's vertical band overlapping "
    .. "the V2 downstream clip's shifted region — per-track contoured runs.")

layout:cleanup()
print("✅ Downstream non-active clips: per-track contour, no per-clip outlines, no cross-track bbox")
