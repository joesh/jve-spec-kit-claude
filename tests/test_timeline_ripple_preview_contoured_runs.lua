#!/usr/bin/env luajit

-- Contract: downstream preview outlines are CONTOURED — they follow the
-- actual clip positions per track, NOT a single bbox spanning the entire
-- shift extent. Clips whose pixel-gap is smaller than 1/20 of the
-- viewport width COALESCE into a single outline run (visual smoothing).
-- Runs entirely outside the visible viewport are CULLED.
--
-- Three properties this test pins:
-- A. Large gap between two clips → two separate outlines (not bridged).
-- B. Small gap between two clips → one merged outline.
-- C. Off-screen clip → not outlined at all.

require("test_env")

local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local Clip = require("models.clip")
local TimelineActiveRegion = require("core.timeline_active_region")

-- Viewport 0..6000 frames, 1800 px wide → 0.3 px/frame.
-- Coalesce threshold = width/20 = 90 px = 300 frames.
-- Setup:
--   v1_user_clip  at frame 100, dur 200  → user-dragged OUT edge
--   v1_close_a    at frame 1000, dur 100 (downstream-shifted to 900)
--   v1_close_b    at frame 1300, dur 100 (downstream-shifted to 1200)
--     gap between close_a end (1000) and close_b start (1200) = 200 frames
--     = 60 px (< 90 px threshold) → MERGED
--   v1_far        at frame 3000, dur 100 (downstream-shifted to 2900)
--     gap between close_b end (1300) and far start (2900) = 1600 frames
--     = 480 px (> 90 px threshold) → SEPARATE outline
--   v1_offscreen  at frame 7000, dur 100 (shifted to 6900) — beyond viewport
--     → CULLED (no outline)
local TEST_DB = "/tmp/jve/test_timeline_ripple_preview_contoured_runs.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_user_clip", "v1_close_a"},
        v1_user_clip = {sequence_start = 100,  duration = 200},
        v1_close_a   = {sequence_start = 1000, duration = 100},
    }
})
local clips, tracks = layout.clips, layout.tracks
local _master = layout.master_seq_for_media[layout.media.main.id]

local function add_v1_clip(name, start, dur)
    return Clip.create({
        name = name, project_id = layout.project_id,
        owner_sequence_id = layout.sequence_id, sequence_id = _master,
        track_id = tracks.v1.id,
        sequence_start_frame = start, duration_frames = dur,
        source_in_frame = 0, source_out_frame = dur,
        fps_mismatch_policy = "resample", volume = 1.0,
        playhead_frame = 0, enabled = 1,
    })
end
local close_b_id    = add_v1_clip("close_b",    1300, 100)
local far_id        = add_v1_clip("far",        3000, 100)
local offscreen_id  = add_v1_clip("offscreen",  7000, 100)
assert(close_b_id ~= "" and far_id ~= "" and offscreen_id ~= "")

layout:init_timeline_state()

local width, height = 1800, 200
local TRACK_HEIGHT = 80
local V1_Y = 0
local view = {
    widget = {}, state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}},
    track_layout_cache = {
        by_index = {[1] = {y = V1_Y, height = TRACK_HEIGHT}},
        by_id = {[tracks.v1.id] = {y = V1_Y, height = TRACK_HEIGHT}},
    },
    debug_id = "contoured-runs",
}
function view.update_layout_cache() end
function view.get_track_visual_height(tid) return TRACK_HEIGHT end
function view.get_track_id_at_y(y) return tracks.v1.id end
function view.get_track_y_by_id(tid) return V1_Y end

-- Drag the user clip's OUT edge by -100 (a small ripple LEFT shifts
-- everything downstream by -100). Resulting positions:
--   close_a   1000 → 900
--   close_b   1300 → 1200
--   far       3000 → 2900
--   offscreen 7000 → 6900 (still offscreen)
local user_edge = {clip_id = clips.v1_user_clip.id, edge_type = "out",
                   track_id = tracks.v1.id, trim_type = "ripple"}
view.drag_state = {
    type = "edges", edges = {user_edge}, lead_edge = user_edge, delta_frames = -100,
}
view.drag_state.timeline_active_region =
    TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot =
    TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)
timeline_state.set_edge_selection({user_edge})

local drawn = {}
local original_timeline = timeline
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() drawn = {} end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(drawn, {x = x, y = y, w = w, h = h, color = color})
    end,
    add_line = function() end, add_text = function() end, update = function() end,
}
local ok, err = pcall(function() timeline_renderer.render(view) end)
timeline = original_timeline
assert(ok, "renderer errored: " .. tostring(err))

local PREVIEW = "#ffff00"
local function px(f) return timeline_state.time_to_pixel(f, width) end

-- Collect yellow rects in V1's vertical band (the user-affected clip's
-- per-clip outline is in the same band but is independent of the
-- downstream contour assertions below).
local function in_v1_band(r) return r.y >= V1_Y and r.y < V1_Y + TRACK_HEIGHT end
local v1_yellow = {}
for _, r in ipairs(drawn) do
    if r.color == PREVIEW and in_v1_band(r) then
        table.insert(v1_yellow, r)
    end
end

-- The downstream content forms two visual groups after coalescing:
--   group 1: close_a + close_b   → outline x ≈ px(900)..px(1300)
--   group 2: far                 → outline x ≈ px(2900)..px(3000)
-- The offscreen clip (shifted to 6900) must contribute NO rect.
local group1_left, group1_right = px(900),  px(1300)
local group2_left, group2_right = px(2900), px(3000)
local offscreen_left = px(6900)

local function approx(a, b, tol) return math.abs(a - b) <= (tol or 2) end

-- Property A: group 1 (close_a + close_b) gets exactly one outline. Test by
-- presence of a rect whose left edge is at group1_left and whose width
-- spans group1_right - group1_left (the merged top or bottom horizontal).
local found_group1_top_or_bottom = false
for _, r in ipairs(v1_yellow) do
    if approx(r.x, group1_left) and approx(r.x + r.w, group1_right)
       and r.h <= 4 then  -- horizontal stroke (thin)
        found_group1_top_or_bottom = true; break
    end
end
assert(found_group1_top_or_bottom,
    string.format("Expected ONE merged outline spanning close_a + close_b "
        .. "(x=%d..%d). The 200-frame gap (60px) between them is below the "
        .. "1/20-viewport-width threshold (90px) and must coalesce.",
        group1_left, group1_right))

-- Property B: a SEPARATE outline exists for the far clip. Its outline
-- left edge is at group2_left (1600 frames / 480 px from group 1's right
-- edge — well above the 90 px threshold).
local found_group2 = false
for _, r in ipairs(v1_yellow) do
    if approx(r.x, group2_left) and approx(r.x + r.w, group2_right)
       and r.h <= 4 then
        found_group2 = true; break
    end
end
assert(found_group2,
    string.format("Expected a SEPARATE outline for the far clip "
        .. "(x=%d..%d). The 1600-frame gap (480px) above the 90px threshold "
        .. "must NOT coalesce with close_a/close_b.",
        group2_left, group2_right))

-- Property C: no rect bridges the gap between group 1 and group 2.
-- A bridging rect would span from group1_left (or further left) past
-- group2_left.
for _, r in ipairs(v1_yellow) do
    if r.x <= group1_left + 2 and (r.x + r.w) >= group2_left - 2 and r.h <= 4 then
        assert(false, string.format(
            "Found bridging outline (x=%d w=%d) across the 480px gap — "
            .. "above-threshold gaps must split into separate runs.", r.x, r.w))
    end
end

-- Property D: nothing outlined at the offscreen clip's shifted position.
for _, r in ipairs(v1_yellow) do
    if approx(r.x, offscreen_left, 3) then
        assert(false, string.format(
            "Found outline rect at offscreen position x=%d (clip shifted "
            .. "to frame 6900, beyond viewport 0..6000). Offscreen runs "
            .. "must be culled.", r.x))
    end
end

layout:cleanup()
print("✅ Downstream preview: contoured per-track runs, gap-coalesced, offscreen culled")
