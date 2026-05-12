#!/usr/bin/env luajit

-- Test TimelineZoomIn and TimelineZoomOut commands
-- Verifies: zoom factors, minimum viewport enforcement, integer frame math
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_timeline_zoom_in_out.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('default_project', 'Default Project', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'default_sequence', 'default_project', 'Sequence', 'sequence',
        30, 1, 48000, 1920, 1080, 0, 300, 150,
        '[]', '[]', '[]', 0, %d, %d
    );
]], now, now, now, now))

command_manager.init('default_sequence', 'default_project')

print("=== TimelineZoomIn / TimelineZoomOut Tests ===")

-- Verify real state loaded from DB
assert(timeline_state.get_viewport_duration() == 300,
    string.format("Initial viewport expected 300, got %d", timeline_state.get_viewport_duration()))

-- Test 1: ZoomIn halves duration (multiplies by 0.5)
print("Test 1: ZoomIn halves duration")
local result = command_manager.execute("TimelineZoomIn", { project_id = "default_project" })
assert(result.success, "TimelineZoomIn should succeed: " .. tostring(result.error_message))
-- 300 * 0.5 = 150 frames (5 seconds)
assert(timeline_state.get_viewport_duration() == 150,
    string.format("ZoomIn should reduce to 150 frames (5s), got %d", timeline_state.get_viewport_duration()))

-- Test 2: ZoomOut doubles duration (multiplies by 2.0)
print("Test 2: ZoomOut doubles duration")
timeline_state.set_viewport_duration(300)  -- reset to 10 seconds
result = command_manager.execute("TimelineZoomOut", { project_id = "default_project" })
assert(result.success, "TimelineZoomOut should succeed: " .. tostring(result.error_message))
-- 300 * 2.0 = 600 frames (20 seconds)
assert(timeline_state.get_viewport_duration() == 600,
    string.format("ZoomOut should increase to 600 frames (20s), got %d", timeline_state.get_viewport_duration()))

-- Test 3: ZoomIn enforces minimum 1 second viewport
print("Test 3: ZoomIn enforces minimum 1 second viewport")
timeline_state.set_viewport_duration(30)  -- 1 second exactly
result = command_manager.execute("TimelineZoomIn", { project_id = "default_project" })
assert(result.success, "TimelineZoomIn should succeed at minimum")
-- 30 * 0.5 = 15 frames, but minimum is 30 frames (1 second)
assert(timeline_state.get_viewport_duration() == 30,
    string.format("ZoomIn should stay at minimum 30 frames (1s), got %d", timeline_state.get_viewport_duration()))

-- Test 4: Multiple ZoomIn calls accumulate
print("Test 4: Multiple ZoomIn calls accumulate")
timeline_state.set_viewport_duration(300)  -- Start at 10 seconds
command_manager.execute("TimelineZoomIn", { project_id = "default_project" })  -- 150 frames
command_manager.execute("TimelineZoomIn", { project_id = "default_project" })  -- 75 frames
-- 300 * 0.5 * 0.5 = 75
assert(timeline_state.get_viewport_duration() == 75,
    string.format("Two ZoomIn calls should result in 75 frames, got %d", timeline_state.get_viewport_duration()))

-- Test 5: Multiple ZoomOut calls accumulate
print("Test 5: Multiple ZoomOut calls accumulate")
timeline_state.set_viewport_duration(300)  -- Start at 10 seconds
command_manager.execute("TimelineZoomOut", { project_id = "default_project" })  -- 600 frames
command_manager.execute("TimelineZoomOut", { project_id = "default_project" })  -- 1200 frames
-- 300 * 2.0 * 2.0 = 1200
assert(timeline_state.get_viewport_duration() == 1200,
    string.format("Two ZoomOut calls should result in 1200 frames, got %d", timeline_state.get_viewport_duration()))

-- Test 6: ZoomIn then ZoomOut returns to original
print("Test 6: ZoomIn/ZoomOut round-trip")
timeline_state.set_viewport_duration(300)  -- 10 seconds
command_manager.execute("TimelineZoomIn", { project_id = "default_project" })  -- 150 frames
command_manager.execute("TimelineZoomOut", { project_id = "default_project" })  -- 150 * 2.0 = 300
-- 300 * 0.5 * 2.0 = 300 exactly
assert(timeline_state.get_viewport_duration() == 300,
    string.format("ZoomIn/ZoomOut round-trip should return to 300 frames, got %d", timeline_state.get_viewport_duration()))

print("✅ TimelineZoomIn/ZoomOut tests passed")
