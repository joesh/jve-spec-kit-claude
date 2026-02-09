#!/usr/bin/env luajit

-- Test TimelineZoomIn and TimelineZoomOut commands
-- Verifies: zoom factors, minimum viewport enforcement, Rational handling

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_timeline_zoom_in_out.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30, 1, 1920, 1080);
]])

-- Mock timeline_state with viewport tracking
local timeline_state = {
    viewport_duration = 300,  -- 10 seconds @ 30fps
    viewport_start_time = 0,
    playhead_position = 150,
    clips = {},
}

function timeline_state.get_viewport_duration() return timeline_state.viewport_duration end
function timeline_state.set_viewport_duration(dur) timeline_state.viewport_duration = dur end
function timeline_state.get_viewport_start_time() return timeline_state.viewport_start_time end
function timeline_state.set_viewport_start_time(start) timeline_state.viewport_start_time = start end
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(pos) timeline_state.playhead_position = pos end
function timeline_state.get_clips() return timeline_state.clips end
function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.set_selection(_) end
function timeline_state.reload_clips() end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end
function timeline_state.capture_viewport() return {start_value = 0, duration_value = 500} end
function timeline_state.restore_viewport(_) end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init('default_sequence', 'default_project')

print("=== TimelineZoomIn / TimelineZoomOut Tests ===")

-- Test 1: ZoomIn reduces duration by 20% (multiplies by 0.8)
print("Test 1: ZoomIn reduces duration by 20%")
timeline_state.viewport_duration = 300  -- 10 seconds
local result = command_manager.execute("TimelineZoomIn", { project_id = "default_project" })
assert(result.success, "TimelineZoomIn should succeed: " .. tostring(result.error_message))
-- 300 * 0.8 = 240 frames (8 seconds) - viewport_duration is now integer
assert(timeline_state.viewport_duration == 240,
    string.format("ZoomIn should reduce to 240 frames (8s), got %d", timeline_state.viewport_duration))

-- Test 2: ZoomOut increases duration by 25% (multiplies by 1.25)
print("Test 2: ZoomOut increases duration by 25%")
timeline_state.viewport_duration = 300  -- 10 seconds
result = command_manager.execute("TimelineZoomOut", { project_id = "default_project" })
assert(result.success, "TimelineZoomOut should succeed: " .. tostring(result.error_message))
-- 300 * 1.25 = 375 frames (12.5 seconds) - viewport_duration is now integer
assert(timeline_state.viewport_duration == 375,
    string.format("ZoomOut should increase to 375 frames (12.5s), got %d", timeline_state.viewport_duration))

-- Test 3: ZoomIn enforces minimum 1 second viewport
print("Test 3: ZoomIn enforces minimum 1 second viewport")
timeline_state.viewport_duration = 30  -- 1 second exactly
result = command_manager.execute("TimelineZoomIn", { project_id = "default_project" })
assert(result.success, "TimelineZoomIn should succeed at minimum")
-- 30 * 0.8 = 24 frames, but minimum is 30 frames (1 second) - viewport_duration is now integer
assert(timeline_state.viewport_duration == 30,
    string.format("ZoomIn should stay at minimum 30 frames (1s), got %d", timeline_state.viewport_duration))

-- Test 4: Multiple ZoomIn calls accumulate
print("Test 4: Multiple ZoomIn calls accumulate")
timeline_state.viewport_duration = 300  -- Start at 10 seconds
command_manager.execute("TimelineZoomIn", { project_id = "default_project" })  -- 240 frames
command_manager.execute("TimelineZoomIn", { project_id = "default_project" })  -- 192 frames
-- 300 * 0.8 * 0.8 = 192 - viewport_duration is now integer
assert(timeline_state.viewport_duration == 192,
    string.format("Two ZoomIn calls should result in 192 frames, got %d", timeline_state.viewport_duration))

-- Test 5: Multiple ZoomOut calls accumulate
print("Test 5: Multiple ZoomOut calls accumulate")
timeline_state.viewport_duration = 300  -- Start at 10 seconds
command_manager.execute("TimelineZoomOut", { project_id = "default_project" })  -- 375 frames
command_manager.execute("TimelineZoomOut", { project_id = "default_project" })  -- 468.75 -> 468 frames
-- 300 * 1.25 * 1.25 = 468.75 (floored to 468) - viewport_duration is now integer
local expected_min = 468
local expected_max = 469
assert(timeline_state.viewport_duration >= expected_min and timeline_state.viewport_duration <= expected_max,
    string.format("Two ZoomOut calls should result in 468-469 frames, got %d", timeline_state.viewport_duration))

-- Test 6: ZoomIn then ZoomOut returns close to original
print("Test 6: ZoomIn/ZoomOut round-trip")
timeline_state.viewport_duration = 300  -- 10 seconds
command_manager.execute("TimelineZoomIn", { project_id = "default_project" })  -- 240 frames
command_manager.execute("TimelineZoomOut", { project_id = "default_project" })  -- 300 frames
-- 300 * 0.8 * 1.25 = 300 exactly - viewport_duration is now integer
assert(timeline_state.viewport_duration == 300,
    string.format("ZoomIn/ZoomOut round-trip should return to 300 frames, got %d", timeline_state.viewport_duration))

print("✅ TimelineZoomIn/ZoomOut tests passed")
