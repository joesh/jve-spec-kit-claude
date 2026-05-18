#!/usr/bin/env luajit

-- Zoom-to-fit must produce symmetric padding around media content.
-- Bug: all buffer was applied at the end (10% right, 0% left), giving
-- lopsided viewport with ~50% wasted space on the right.
-- Also verifies gap clips don't inflate the content bounds.

local test_env = require('test_env')

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Media = require('models.media')
local timeline_state = require('ui.timeline.timeline_state')
local ui_constants = require('core.ui_constants')

local TEST_DB = "/tmp/jve/test_zoom_to_fit.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height,
                           playhead_frame, view_start_frame, view_duration_frames,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos,
                           current_sequence_number, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 25, 1, 48000, 1920, 1080,
            0, 0, 240, '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v2', 'seq', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

command_manager.init('seq', 'proj')

-- Create media + masterclip
local media = Media.create({
    id = "m1", project_id = "proj",
    file_path = "/tmp/jve/m1.mov", name = "m1.mov",
    duration_frames = 5000,
    fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
})
assert(media and media:save(db), "media save")
local mc_id = test_env.create_test_masterclip_sequence('proj', 'MC1', 25, 1, 5000, "m1")

-- Insert clip on V1 at frame 100
local cmd = Command.create("Insert", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("target_video_track_id", "v1")
cmd:set_parameter("source_sequence_id", mc_id)
cmd:set_parameter("clip_name", "clip_a")
cmd:set_parameter("created_clip_ids", {"clip_a"})
cmd:set_parameter("sequence_start_frame", 100)
local r = command_manager.execute(cmd)
assert(r and r.success, "Insert failed: " .. tostring(r and r.error_message))

local clip_a = timeline_state.get_clip_by_id("clip_a")
assert(clip_a, "clip_a must exist")
local content_start = clip_a.sequence_start
local content_end = content_start + clip_a.duration
local content_dur = content_end - content_start
print(string.format("Media clip: start=%d end=%d dur=%d", content_start, content_end, content_dur))

-- ============================================================
-- Test 1: Symmetric padding
-- ============================================================
print("\nTest 1: Symmetric padding")

r = command_manager.execute("TimelineZoomFit", {project_id = "proj"})
assert(r and r.success, "TimelineZoomFit failed: " .. tostring(r and r.error_message))

local vp_start = timeline_state.get_viewport_start_time()
local vp_dur = timeline_state.get_viewport_duration()
local vp_end = vp_start + vp_dur

local left_pad = content_start - vp_start
local right_pad = vp_end - content_end
print(string.format("  Viewport: start=%d end=%d dur=%d", vp_start, vp_end, vp_dur))
print(string.format("  Left pad=%d  Right pad=%d", left_pad, right_pad))

-- Total padding should be ~10% of content (5% each side)
local total_pad = left_pad + right_pad
local expected_total = math.floor(content_dur * ui_constants.TIMELINE.ZOOM_TO_FIT_PADDING) * 2
-- When left is clamped to floor (0), unused left pad goes to right
-- so total padding is preserved even if not perfectly symmetric
assert(total_pad == expected_total, string.format(
    "Total padding should be %d (10%% of %d), got %d (left=%d right=%d)",
    expected_total, content_dur, total_pad, left_pad, right_pad))

-- Left pad is clamped by floor (content starts at 100, floor=0, pad=250 → left=100)
assert(vp_start >= 0, "Viewport start must not go below timecode origin")

print("  PASS: correct padding with floor clamp")

-- ============================================================
-- Test 2: compute_zoom_to_fit standalone
-- ============================================================
print("\nTest 2: compute_zoom_to_fit standalone")

-- No floor: symmetric
local s, d = ui_constants.compute_zoom_to_fit(1000, 3000)
assert(s == 900 and d == 2200, string.format("no floor: start=%d dur=%d", s, d))
print("  PASS: symmetric when no floor")

-- Floor below content: no effect
s, d = ui_constants.compute_zoom_to_fit(1000, 3000, 0)
assert(s == 900 and d == 2200, string.format("floor below: start=%d dur=%d", s, d))
print("  PASS: floor below content has no effect")

-- Floor clips left pad: total preserved, shift right
s, d = ui_constants.compute_zoom_to_fit(1000, 3000, 950)
assert(s == 950 and d == 2200, string.format("floor clips: start=%d dur=%d", s, d))
print("  PASS: floor clamps start, total padding preserved")

-- Bad inputs: assert on invalid args
local ok, err = pcall(ui_constants.compute_zoom_to_fit, nil, 3000)
assert(not ok and err:find("min_start must be number"), "should reject nil min_start")
ok, err = pcall(ui_constants.compute_zoom_to_fit, 1000, nil)
assert(not ok and err:find("max_end must be number"), "should reject nil max_end")
ok, err = pcall(ui_constants.compute_zoom_to_fit, 3000, 1000)
assert(not ok and err:find("must exceed"), "should reject max_end <= min_start")
ok, err = pcall(ui_constants.compute_zoom_to_fit, 1000, 3000, "bad")
assert(not ok and err:find("floor_start must be number"), "should reject non-number floor")
print("  PASS: bad inputs assert with actionable messages")

-- ============================================================
-- Test 3: Gap clips don't inflate content bounds
-- ============================================================
print("\nTest 3: Gap clips don't inflate bounds")

-- V2 has no media — only gap clips. These should NOT affect zoom-to-fit.
local all_clips = timeline_state.get_clips()
local gap_count = 0
for _, c in ipairs(all_clips) do
    if c.clip_kind == "gap" then gap_count = gap_count + 1 end
end
print(string.format("  %d total clips, %d gaps", #all_clips, gap_count))

-- Viewport should still match content bounds + 5% padding, not be inflated by gaps
assert(vp_dur <= content_dur * 1.15, string.format(
    "Viewport duration %d is >15%% larger than content %d — gaps may be inflating bounds",
    vp_dur, content_dur))

print("  PASS: gaps don't inflate viewport")

-- ============================================================
-- Test 4: Toggle restores original viewport
-- ============================================================
print("\nTest 4: Toggle restore")

-- Set a manual viewport within the valid extent
timeline_state.set_viewport_duration(3000)
timeline_state.set_viewport_start_time(200)
local manual_start = timeline_state.get_viewport_start_time()
local manual_dur = timeline_state.get_viewport_duration()

-- Clear toggle state from Test 1, then zoom to fit
local zoom_fit_mod = require("core.commands.timeline_zoom_fit")
zoom_fit_mod.clear_toggle_state()

r = command_manager.execute("TimelineZoomFit", {project_id = "proj"})
assert(r and r.success, "ZoomFit failed")
assert(timeline_state.get_viewport_duration() ~= manual_dur, "ZoomFit should change viewport")

-- Second Shift-Z: toggle back
r = command_manager.execute("TimelineZoomFit", {project_id = "proj"})
assert(r and r.success, "ZoomFit toggle failed")
assert(timeline_state.get_viewport_start_time() == manual_start,
    string.format("Toggle should restore start %d, got %d", manual_start, timeline_state.get_viewport_start_time()))
assert(timeline_state.get_viewport_duration() == manual_dur,
    string.format("Toggle should restore dur %d, got %d", manual_dur, timeline_state.get_viewport_duration()))

print("  PASS: toggle restores previous viewport")

-- ============================================================
-- Test 5: All-gaps sequence returns false
-- ============================================================
print("\nTest 5: No media clips → failure")

-- Delete clip_a, leaving only gaps
local Clip = require('models.clip')
local clip_obj = Clip.load_optional("clip_a")
assert(clip_obj and clip_obj:delete(), "delete clip_a for test 5")
timeline_state.reload_clips("seq")

zoom_fit_mod.clear_toggle_state()
r = command_manager.execute("TimelineZoomFit", {project_id = "proj"})
assert(not r.success, "TimelineZoomFit should fail with no media clips")
print("  PASS: returns false when no media clips")

print("\n✅ test_zoom_to_fit.lua passed")
