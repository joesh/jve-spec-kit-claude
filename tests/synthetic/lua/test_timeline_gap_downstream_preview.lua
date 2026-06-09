#!/usr/bin/env luajit

require("test_env")

local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("synthetic.helpers.ripple_layout")
local Clip = require("models.clip")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_gap_downstream_preview.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left = {sequence_start = 0, duration = 1000},
        v1_right = {sequence_start = 1600, duration = 1000},
        v2 = {sequence_start = 1200, duration = 1200}
    }
})
local clips = layout.clips
local tracks = layout.tracks

-- Insert a downstream clip on V2 before initializing the timeline state.
-- Reuse the layout's primary master so the master row + media_ref exist.
local _primary_master = layout.master_seq_for_media[layout.media.main.id]
local downstream = Clip.create({
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
-- V13 Clip.create returns a string id (no :save method).
assert(downstream and downstream ~= "", "Failed to insert downstream clip")
local downstream_id = downstream

layout:init_timeline_state()

downstream = Clip.load(downstream_id)
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

local v1_gap_start = clips.v1_left.sequence_start + clips.v1_left.duration
local v1_gap_id = layout:gap_id("v1", v1_gap_start)
local gap_edge = {clip_id = v1_gap_id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"}
local clip_edge = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}

view.drag_state = {
    type = "edges",
    edges = {gap_edge, clip_edge},
    lead_edge = gap_edge,
    delta_frames = -200
}
view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)

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
local blocks = preview.shift_blocks or {}
assert(type(blocks) == "table" and #blocks > 0, "Expected shift_blocks for downstream ripple preview")

local global = nil
local track_block = nil
for _, block in ipairs(blocks) do
    if block.track_id == tracks.v2.id then
        track_block = block
    elseif not block.track_id and not global then
        global = block
    end
end
local active_block = track_block or global
assert(active_block and active_block.delta_frames and active_block.start_frames, "Expected a usable shift block for V2")

local shifted_start_frames = downstream.sequence_start
if shifted_start_frames >= active_block.start_frames then
    shifted_start_frames = shifted_start_frames + active_block.delta_frames
end
local shifted_px = timeline_state.time_to_pixel(shifted_start_frames, width)

-- The downstream V2 mover is now enclosed by the single multi-track
-- block outline (see test_timeline_ripple_preview_single_block_outline.lua).
-- Assert that some preview-color rect intersects the V2 downstream
-- clip's shifted region — i.e., the clip is visually marked by the
-- preview, regardless of whether the mark is a per-clip outline or part
-- of a larger enclosing block.
local preview_color = "#ffff00"
local v2_entry = view.track_layout_cache.by_id[tracks.v2.id]
local shifted_end_px = timeline_state.time_to_pixel(
    shifted_start_frames + downstream.duration, width)
local v2_band_top    = v2_entry.y
local v2_band_bottom = v2_entry.y + v2_entry.height
local function rects_overlap(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end
local found_preview_rect = false
for _, rect in ipairs(drawn_rects) do
    if rect.color == preview_color then
        if rects_overlap(rect.x, rect.y, rect.w, rect.h,
                         shifted_px, v2_band_top,
                         shifted_end_px - shifted_px, v2_band_bottom - v2_band_top) then
            found_preview_rect = true
            break
        end
    end
end
assert(found_preview_rect,
    string.format("Expected a preview-color rect intersecting the V2 downstream "
        .. "clip's shifted region (x=%d..%d, y=%d..%d, shifted_start=%d)",
        shifted_px, shifted_end_px, v2_band_top, v2_band_bottom, shifted_start_frames))

print("✅ Downstream clips shift preview when gaps ripple across tracks")
