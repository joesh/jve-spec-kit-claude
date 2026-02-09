#!/usr/bin/env luajit

-- Test StepFrame command: frame-stepping in both timeline and source modes

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_step_frame_command.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('proj1', 'Test Project');
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, width, height)
    VALUES ('seq1', 'proj1', 'Sequence', 30, 1, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1);
]])

-- Mock timeline_state (used by pc in timeline mode)
local timeline_state = {
    playhead_position = 10,
    clips = {},
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

-- Mock playback_controller — mirrors real set_position behavior per mode
local mock_pc = {
    state = "stopped",
    timeline_mode = true,
    fps_num = 30,
    fps_den = 1,
    total_frames = 1000,
    _position = 10,
    audio_played = nil,
    seeked_to = nil,
    _last_committed_frame = nil,
}
function mock_pc.has_source() return mock_pc.total_frames > 0 and mock_pc.fps_num and mock_pc.fps_num > 0 end
function mock_pc.play_frame_audio(frame_idx) mock_pc.audio_played = frame_idx end
function mock_pc.is_playing() return mock_pc.state == "playing" end
function mock_pc.seek(frame_idx)
    mock_pc.seeked_to = frame_idx
    mock_pc._position = frame_idx
    mock_pc._last_committed_frame = math.floor(frame_idx)
end

-- Mirrors the real set_position: timeline mode writes timeline_state,
-- source mode calls seek when parked
function mock_pc.get_position()
    if mock_pc.timeline_mode then
        local pos = timeline_state.playhead_position
        -- Handle both integer and table with .frames
        if type(pos) == "table" and pos.frames then
            return pos.frames
        end
        return pos
    end
    return mock_pc._position
end
function mock_pc.set_position(v)
    if mock_pc.timeline_mode then
        -- Store as integer frame
        timeline_state.set_playhead_position(math.floor(v))
        mock_pc._position = v
    else
        mock_pc._position = v
        if mock_pc.state ~= "playing" then
            mock_pc.seek(v)
        end
    end
end

package.loaded['core.playback.playback_controller'] = mock_pc

command_manager.init('seq1', 'proj1')

print("=== StepFrame Command Tests ===")

-- Test 1: Step right 1 frame in timeline mode
print("Test 1: Step right 1 frame (timeline mode)")
mock_pc.timeline_mode = true
timeline_state.playhead_position = 10
mock_pc.audio_played = nil
local result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
})
assert(result.success, "StepFrame right should succeed: " .. tostring(result.error_message))
assert(timeline_state.playhead_position == 11,
    string.format("Expected frame 11, got %d", timeline_state.playhead_position))
assert(mock_pc.audio_played == 11,
    string.format("Expected audio at frame 11, got %s", tostring(mock_pc.audio_played)))

-- Test 2: Step left 1 frame in timeline mode
print("Test 2: Step left 1 frame (timeline mode)")
timeline_state.playhead_position = 10
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
})
assert(result.success, "StepFrame left should succeed")
assert(timeline_state.playhead_position == 9,
    string.format("Expected frame 9, got %d", timeline_state.playhead_position))

-- Test 3: Step left clamped at 0
print("Test 3: Step left clamped at frame 0")
timeline_state.playhead_position = 0
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
})
assert(result.success, "StepFrame left at 0 should succeed")
assert(timeline_state.playhead_position == 0,
    string.format("Expected frame 0, got %d", timeline_state.playhead_position))

-- Test 4: Shift step = 1 second (30 frames at 30fps)
print("Test 4: Shift step = 1 second jump")
timeline_state.playhead_position = 10
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
    shift = true,
})
assert(result.success, "StepFrame shift-right should succeed")
assert(timeline_state.playhead_position == 40,
    string.format("Expected frame 40, got %d", timeline_state.playhead_position))

-- Test 5: Shift step left clamped at 0
print("Test 5: Shift step left clamped at 0")
timeline_state.playhead_position = 10
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
    shift = true,
})
assert(result.success, "StepFrame shift-left should succeed")
assert(timeline_state.playhead_position == 0,
    string.format("Expected frame 0, got %d", timeline_state.playhead_position))

-- Test 6: Source mode step right (seek called via set_position)
print("Test 6: Source mode step right")
mock_pc.timeline_mode = false
mock_pc._position = 50
mock_pc.audio_played = nil
mock_pc.seeked_to = nil
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
})
assert(result.success, "StepFrame source-right should succeed: " .. tostring(result.error_message))
assert(mock_pc._position == 51,
    string.format("Expected source position 51, got %d", mock_pc._position))
assert(mock_pc.seeked_to == 51,
    string.format("Expected seek to frame 51, got %s", tostring(mock_pc.seeked_to)))
assert(mock_pc.audio_played == 51,
    string.format("Expected audio at frame 51, got %s", tostring(mock_pc.audio_played)))

-- Test 7: Source mode step left clamped at 0
print("Test 7: Source mode step left clamped at 0")
mock_pc.timeline_mode = false
mock_pc._position = 0
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = -1,
})
assert(result.success, "StepFrame source-left at 0 should succeed")
assert(mock_pc._position == 0,
    string.format("Expected source position 0, got %d", mock_pc._position))

-- Test 8: Source mode shift step
print("Test 8: Source mode shift step right")
mock_pc.timeline_mode = false
mock_pc._position = 10
result = command_manager.execute("StepFrame", {
    project_id = "proj1",
    direction = 1,
    shift = true,
})
assert(result.success, "StepFrame source shift-right should succeed")
assert(mock_pc._position == 40,
    string.format("Expected source position 40, got %d", mock_pc._position))

print("✅ test_step_frame_command.lua passed")
