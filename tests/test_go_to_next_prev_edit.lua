#!/usr/bin/env luajit

-- Test GoToNextEdit and GoToPrevEdit navigation commands
-- Verifies: navigation to clip boundaries, handling of gaps, edge cases

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_go_to_next_prev_edit.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30, 1, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
]])

-- Create clips: clip_a [0, 100), gap [100, 200), clip_b [200, 350)
-- Edit points: 0, 100, 200, 350
db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at)
    VALUES ('media_a', 'default_project', 'clip_a.mov', '/tmp/clip_a.mov', 100, 30.0, 0, 0);
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at)
    VALUES ('media_b', 'default_project', 'clip_b.mov', '/tmp/clip_b.mov', 150, 30.0, 0, 0);

    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip_a', 'track_v1', 'media_a', 0, 100, 0, 100, 30, 1, 1);
    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip_b', 'track_v1', 'media_b', 200, 150, 0, 150, 30, 1, 1);
]])

-- Mock timeline_state
local timeline_state = {
    playhead_position = 50,  -- Start in middle of clip_a
    clips = {
        {id = 'clip_a', timeline_start = 0, duration = 100},
        {id = 'clip_b', timeline_start = 200, duration = 150},
    },
}

function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.set_selection(_) end
function timeline_state.reload_clips() end
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(pos) timeline_state.playhead_position = pos end
function timeline_state.get_clips() return timeline_state.clips end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end
function timeline_state.capture_viewport() return {start_value = 0, duration_value = 500} end
function timeline_state.restore_viewport(_) end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init('default_sequence', 'default_project')

print("=== GoToNextEdit / GoToPrevEdit Tests ===")

-- Test 1: GoToNextEdit from middle of clip_a moves to end of clip_a (frame 100)
print("Test 1: GoToNextEdit from middle of clip_a")
timeline_state.playhead_position = 50
local result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed: " .. tostring(result.error_message))
assert(timeline_state.playhead_position == 100,
    string.format("GoToNextEdit should move to frame 100, got %d", timeline_state.playhead_position))

-- Test 2: GoToNextEdit from frame 100 (end of clip_a) moves to frame 200 (start of clip_b)
print("Test 2: GoToNextEdit from end of clip_a")
timeline_state.playhead_position = 100
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed")
assert(timeline_state.playhead_position == 200,
    string.format("GoToNextEdit should move to frame 200, got %d", timeline_state.playhead_position))

-- Test 3: GoToNextEdit from frame 200 moves to frame 350 (end of clip_b)
print("Test 3: GoToNextEdit from start of clip_b")
timeline_state.playhead_position = 200
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed")
assert(timeline_state.playhead_position == 350,
    string.format("GoToNextEdit should move to frame 350, got %d", timeline_state.playhead_position))

-- Test 4: GoToNextEdit at end of timeline stays at end
print("Test 4: GoToNextEdit at end of timeline")
timeline_state.playhead_position = 350
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed at end")
assert(timeline_state.playhead_position == 350,
    string.format("GoToNextEdit should stay at frame 350, got %d", timeline_state.playhead_position))

-- Test 5: GoToPrevEdit from middle of clip_b moves to frame 200
print("Test 5: GoToPrevEdit from middle of clip_b")
timeline_state.playhead_position = 300
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed: " .. tostring(result.error_message))
assert(timeline_state.playhead_position == 200,
    string.format("GoToPrevEdit should move to frame 200, got %d", timeline_state.playhead_position))

-- Test 6: GoToPrevEdit from frame 200 moves to frame 100
print("Test 6: GoToPrevEdit from start of clip_b")
timeline_state.playhead_position = 200
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed")
assert(timeline_state.playhead_position == 100,
    string.format("GoToPrevEdit should move to frame 100, got %d", timeline_state.playhead_position))

-- Test 7: GoToPrevEdit from frame 100 moves to frame 0
print("Test 7: GoToPrevEdit from end of clip_a")
timeline_state.playhead_position = 100
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed")
assert(timeline_state.playhead_position == 0,
    string.format("GoToPrevEdit should move to frame 0, got %d", timeline_state.playhead_position))

-- Test 8: GoToPrevEdit at start of timeline stays at start
print("Test 8: GoToPrevEdit at start of timeline")
timeline_state.playhead_position = 0
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed at start")
assert(timeline_state.playhead_position == 0,
    string.format("GoToPrevEdit should stay at frame 0, got %d", timeline_state.playhead_position))

-- Test 9: Navigation in gap (between clips) still finds correct edit points
print("Test 9: GoToNextEdit from gap")
timeline_state.playhead_position = 150  -- In gap between clips
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed from gap")
assert(timeline_state.playhead_position == 200,
    string.format("GoToNextEdit from gap should move to frame 200, got %d", timeline_state.playhead_position))

-- Test 10: GoToPrevEdit from gap
print("Test 10: GoToPrevEdit from gap")
timeline_state.playhead_position = 150  -- In gap
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed from gap")
assert(timeline_state.playhead_position == 100,
    string.format("GoToPrevEdit from gap should move to frame 100, got %d", timeline_state.playhead_position))

-- Test 11: Round-trip navigation
print("Test 11: Next/Prev round-trip")
timeline_state.playhead_position = 50
command_manager.execute("GoToNextEdit", { project_id = "default_project" })  -- -> 100
command_manager.execute("GoToPrevEdit", { project_id = "default_project" })  -- -> 0 (not 50, goes to previous edit)
assert(timeline_state.playhead_position == 0,
    string.format("Round-trip should end at frame 0, got %d", timeline_state.playhead_position))

-- Test 12: Empty timeline - navigation from any position stays at 0
print("Test 12: Navigation on empty timeline")
local saved_clips = timeline_state.clips
timeline_state.clips = {}
timeline_state.playhead_position = 100
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed on empty timeline")
assert(timeline_state.playhead_position == 100,
    string.format("GoToNextEdit on empty timeline should stay at current position, got %d", timeline_state.playhead_position))
timeline_state.clips = saved_clips

print("✅ GoToNextEdit/GoToPrevEdit tests passed")
