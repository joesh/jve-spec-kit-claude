#!/usr/bin/env luajit

-- Test: TimelineZoomInAtMouse / TimelineZoomOutAtMouse use the timeline's
-- last-known pointer frame as the anchor for the viewport duration change.
--
-- Domain behavior: after zooming "at pointer", the frame that was under
-- the cursor stays at the same pixel fraction within the viewport.

require('test_env')

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_zoom_at_pointer.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('default_project', 'Default Project', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'default_sequence', 'default_project', 'Sequence', 'sequence',
        24, 1, 48000, 1920, 1080, 100, 200, 150,
        '[]', '[]', '[]', 0, %d, %d
    );
]], now, now, now, now))

command_manager.init('default_sequence', 'default_project')

print("=== TimelineZoomInAtMouse / TimelineZoomOutAtMouse Tests ===")

-- =============================================================================
-- Test 1: TimelineZoomInAtMouse uses last_pointer_frame as anchor
-- =============================================================================
timeline_state.set_viewport_start_time(100)
timeline_state.set_viewport_duration(200)
timeline_state.set_last_pointer_frame(250)  -- pointer at 75% from left of [100..300]

local old_pointer_fraction = (250 - 100) / 200  -- 0.75

local result = command_manager.execute("TimelineZoomInAtMouse", { project_id = "default_project" })
assert(result.success, "TimelineZoomInAtMouse should succeed: " .. tostring(result.error_message))

local new_start = timeline_state.get_viewport_start_time()
local new_duration = timeline_state.get_viewport_duration()
assert(new_duration == 100, string.format("duration should halve to 100, got %d", new_duration))
local new_pointer_fraction = (250 - new_start) / new_duration
assert(math.abs(new_pointer_fraction - old_pointer_fraction) < 0.05,
    string.format("pointer fraction should stay ~%.3f, got %.3f (new_start=%d new_dur=%d)",
        old_pointer_fraction, new_pointer_fraction, new_start, new_duration))
print("  PASS: zoom-in at pointer preserves pointer pixel fraction")

-- =============================================================================
-- Test 2: TimelineZoomOutAtMouse uses last_pointer_frame as anchor
-- =============================================================================
-- Reset order matters: set duration first (it adjusts start), then start.
timeline_state.set_viewport_duration(200)
timeline_state.set_viewport_start_time(100)
timeline_state.set_last_pointer_frame(150)  -- pointer at 25% from left

old_pointer_fraction = (150 - 100) / 200  -- 0.25

result = command_manager.execute("TimelineZoomOutAtMouse", { project_id = "default_project" })
assert(result.success, "TimelineZoomOutAtMouse should succeed: " .. tostring(result.error_message))

new_start = timeline_state.get_viewport_start_time()
new_duration = timeline_state.get_viewport_duration()
assert(new_duration == 400, string.format("duration should double to 400, got %d", new_duration))
new_pointer_fraction = (150 - new_start) / new_duration
assert(math.abs(new_pointer_fraction - old_pointer_fraction) < 0.05,
    string.format("pointer fraction should stay ~%.3f, got %.3f",
        old_pointer_fraction, new_pointer_fraction))
print("  PASS: zoom-out at pointer preserves pointer pixel fraction")

-- =============================================================================
-- Test 3: AtMouse command with no last_pointer_frame → fails loudly
-- =============================================================================
timeline_state.set_viewport_start_time(100)
timeline_state.set_viewport_duration(200)
timeline_state.set_last_pointer_frame(nil)

result = command_manager.execute("TimelineZoomInAtMouse", { project_id = "default_project" })
assert(not result.success, "AtMouse with no pointer frame should fail")
-- Viewport should be unchanged
assert(timeline_state.get_viewport_duration() == 200,
    "viewport should be unchanged when command fails")
print("  PASS: zoom-at-pointer without tracked pointer frame fails loudly")

print("\n✅ test_zoom_at_pointer.lua passed")
