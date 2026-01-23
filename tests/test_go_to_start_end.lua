#!/usr/bin/env luajit

-- Test GoToStart and GoToEnd navigation commands

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

local TEST_DB = "/tmp/jve/test_go_to_start_end.db"
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

-- Create clips: clip_a [0, 100), clip_b [200, 350)
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
    playhead_position = Rational.new(150, 30, 1),  -- Start in the middle
    clips = {
        {id = 'clip_a', timeline_start = Rational.new(0, 30, 1), duration = Rational.new(100, 30, 1)},
        {id = 'clip_b', timeline_start = Rational.new(200, 30, 1), duration = Rational.new(150, 30, 1)},
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

print("=== GoToStart / GoToEnd Tests ===")

-- Test 1: GoToStart moves playhead to frame 0
print("Test 1: GoToStart moves playhead to frame 0")
timeline_state.playhead_position = Rational.new(150, 30, 1)
local result = command_manager.execute("GoToStart", { project_id = "default_project" })
assert(result.success, "GoToStart should succeed: " .. tostring(result.error_message))
assert(timeline_state.playhead_position.frames == 0,
    string.format("GoToStart should move to frame 0, got %d", timeline_state.playhead_position.frames))

-- Test 2: GoToEnd moves playhead to end of last clip (frame 350)
print("Test 2: GoToEnd moves playhead to end of last clip")
timeline_state.playhead_position = Rational.new(0, 30, 1)
result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success, "GoToEnd should succeed: " .. tostring(result.error_message))
assert(timeline_state.playhead_position.frames == 350,
    string.format("GoToEnd should move to frame 350, got %d", timeline_state.playhead_position.frames))

-- Test 3: GoToStart is idempotent (already at start)
print("Test 3: GoToStart is idempotent")
timeline_state.playhead_position = Rational.new(0, 30, 1)
result = command_manager.execute("GoToStart", { project_id = "default_project" })
assert(result.success, "GoToStart should succeed when already at start")
assert(timeline_state.playhead_position.frames == 0, "GoToStart should stay at 0")

-- Test 4: GoToEnd is idempotent (already at end)
print("Test 4: GoToEnd is idempotent")
timeline_state.playhead_position = Rational.new(350, 30, 1)
result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success, "GoToEnd should succeed when already at end")
assert(timeline_state.playhead_position.frames == 350, "GoToEnd should stay at 350")

-- Test 5: GoToEnd with empty timeline returns 0
print("Test 5: GoToEnd with empty timeline")
timeline_state.clips = {}
timeline_state.playhead_position = Rational.new(100, 30, 1)
result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success, "GoToEnd should succeed with empty timeline")
assert(timeline_state.playhead_position.frames == 0,
    string.format("GoToEnd on empty timeline should go to 0, got %d", timeline_state.playhead_position.frames))

print("✅ GoToStart/GoToEnd navigation tests passed")
