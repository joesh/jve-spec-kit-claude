#!/usr/bin/env luajit

-- Test StepFrame command: frame-stepping in both timeline and source modes
-- Uses REAL timeline_state — no mock.
-- Mock playback_controller and monitor justified: audio playback + engine state

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Forward-declare mock_sv
local mock_sv

-- Mock panel_manager — justified: monitor requires Qt engine
package.loaded['ui.panel_manager'] = {
    get_active_sequence_monitor = function() return mock_sv end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_step_frame_command.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 500, 10, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Mock engine for the sequence monitor
local mock_engine = {
    fps_num = 30,
    fps_den = 1,
    total_frames = 1000,
    _position = 10,
    audio_played = nil,
}
function mock_engine:get_position()
    return self._position
end
function mock_engine:set_position(v)
    self._position = v
    timeline_state.set_playhead_position(math.floor(v))
end
function mock_engine:play_frame_audio(frame_idx)
    self.audio_played = frame_idx
end
function mock_engine:is_playing() return false end
function mock_engine:has_source() return true end

-- Mock sequence monitor with the mock engine
mock_sv = {
    sequence_id = "seq1",
    view_id = "timeline_monitor",
    total_frames = 1000,
    engine = mock_engine,
}
function mock_sv:seek_to_frame(frame)
    local clamped = math.max(0, math.min(math.floor(frame), self.total_frames - 1))
    self.engine._position = clamped
    timeline_state.set_playhead_position(clamped)
end

command_manager.init('seq1', 'proj1')

print("=== StepFrame Command Tests ===")

-- Test 1: Step right 1 frame in timeline mode
print("Test 1: Step right 1 frame (timeline mode)")
mock_engine._position = 10
timeline_state.set_playhead_position(10)
mock_engine.audio_played = nil
local result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
})
assert(result.success, "StepFrame right should succeed: " .. tostring(result.error_message))
assert(timeline_state.get_playhead_position() == 11,
    string.format("Expected frame 11, got %d", timeline_state.get_playhead_position()))
assert(mock_engine.audio_played == 11,
    string.format("Expected audio at frame 11, got %s", tostring(mock_engine.audio_played)))

-- Test 2: Step left 1 frame in timeline mode
print("Test 2: Step left 1 frame (timeline mode)")
mock_engine._position = 10
timeline_state.set_playhead_position(10)
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
})
assert(result.success, "StepFrame left should succeed")
assert(timeline_state.get_playhead_position() == 9,
    string.format("Expected frame 9, got %d", timeline_state.get_playhead_position()))

-- Test 3: Step left clamped at 0
print("Test 3: Step left clamped at frame 0")
mock_engine._position = 0
timeline_state.set_playhead_position(0)
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
})
assert(result.success, "StepFrame left at 0 should succeed")
assert(timeline_state.get_playhead_position() == 0,
    string.format("Expected frame 0, got %d", timeline_state.get_playhead_position()))

-- Test 4: Shift step = 1 second (30 frames at 30fps)
print("Test 4: Shift step = 1 second jump")
mock_engine._position = 10
timeline_state.set_playhead_position(10)
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
    shift = true,
})
assert(result.success, "StepFrame shift-right should succeed")
assert(timeline_state.get_playhead_position() == 40,
    string.format("Expected frame 40, got %d", timeline_state.get_playhead_position()))

-- Test 5: Shift step left clamped at 0
print("Test 5: Shift step left clamped at 0")
mock_engine._position = 10
timeline_state.set_playhead_position(10)
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
    shift = true,
})
assert(result.success, "StepFrame shift-left should succeed")
assert(timeline_state.get_playhead_position() == 0,
    string.format("Expected frame 0, got %d", timeline_state.get_playhead_position()))

-- Test 6: Source mode step right
print("Test 6: Source mode step right")
mock_engine._position = 50
mock_engine.audio_played = nil
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
})
assert(result.success, "StepFrame source-right should succeed: " .. tostring(result.error_message))
assert(mock_engine._position == 51,
    string.format("Expected source position 51, got %d", mock_engine._position))
assert(mock_engine.audio_played == 51,
    string.format("Expected audio at frame 51, got %s", tostring(mock_engine.audio_played)))

-- Test 7: Source mode step left clamped at 0
print("Test 7: Source mode step left clamped at 0")
mock_engine._position = 0
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
})
assert(result.success, "StepFrame source-left at 0 should succeed")
assert(mock_engine._position == 0,
    string.format("Expected source position 0, got %d", mock_engine._position))

-- Test 8: Source mode shift step
print("Test 8: Source mode shift step right")
mock_engine._position = 10
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
    shift = true,
})
assert(result.success, "StepFrame source shift-right should succeed")
assert(mock_engine._position == 40,
    string.format("Expected source position 40, got %d", mock_engine._position))

-- Test 9: fps_den=0 should assert, not fall back to 30fps
print("Test 9: fps_den=0 asserts (NSF)")
mock_engine.fps_den = 0
mock_engine._position = 10
timeline_state.set_playhead_position(10)
local r9 = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
    shift = true,
})
assert(not r9.success, "StepFrame with fps_den=0 should fail, not silently use fallback")
assert(r9.error_message and r9.error_message:find("fps_den"),
    "error should mention fps_den, got: " .. tostring(r9.error_message))
-- Verify playhead unchanged (no fallback math happened)
assert(timeline_state.get_playhead_position() == 10,
    "playhead should be unchanged after assert, got " .. timeline_state.get_playhead_position())
mock_engine.fps_den = 1  -- restore

print("✅ test_step_frame_command.lua passed")
