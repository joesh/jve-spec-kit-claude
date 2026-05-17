#!/usr/bin/env luajit

-- Test MovePlayhead command: duration-literal based playhead movement
-- Uses real DB + real timeline_state. Mock only for panel_manager (Qt engine).

require('test_env')

_G.qt_create_single_shot_timer = function() end

-- Forward-declare mock_monitor
local mock_monitor

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return mock_monitor end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Signals = require('core.signals')

local TEST_DB = "/tmp/jve/test_move_playhead_command.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('seq', 'proj', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 500, 100, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now))

-- Mock sequence monitor — justified: seek_to_frame requires Qt engine for decode
local seeked_frame = nil
local audio_frame = nil

mock_monitor = {
    sequence_id = "seq",
    view_id = "timeline_monitor",
    total_frames = 500,
    sequence = { start_timecode_frame = 0 },
    engine = {
        fps_num = 24, fps_den = 1,
        -- NOTE: get_position reads from engine state, which is updated by seek_to_frame.
        -- This relies on playhead_changed signals firing synchronously.
        get_position = function() return timeline_state.get_playhead_position() end,
        is_playing = function() return false end,
        stop = function() end,
        seek = function() end,
        play_frame_audio = function(_, f) audio_frame = f end,
    },
}
function mock_monitor:seek_to_frame(frame)
    seeked_frame = frame
    timeline_state.set_playhead_position(math.max(0, math.floor(frame)))
end

-- Connect mock monitor to playhead_changed signal (mirrors real SequenceMonitor)
Signals.connect("playhead_changed", function(sequence_id, frame)
    if mock_monitor.sequence_id == sequence_id and type(frame) == "number" then
        mock_monitor:seek_to_frame(frame)
    end
end)

command_manager.init('seq', 'proj')

local function reset(frame)
    seeked_frame = nil
    audio_frame = nil
    local f = frame or 100
    timeline_state.set_playhead_position(f)
    -- Sync the DB row too — the executor reads sequence.playhead_position
    -- (via Sequence.load) for its current frame. In-memory timeline_state
    -- alone won't seed it under the post-017 injection model.
    local seq = require("models.sequence").load("seq")
    seq.playhead_position = f
    seq:save()
end

local function exec(literal)
    return command_manager.execute("MovePlayhead", {
        _positional = {literal},
        project_id = "proj",
    })
end

print("=== MovePlayhead Command Tests ===")

-- Test 1: "1f" from position 100 → seeks to 101
print("Test 1: 1f forward from 100")
reset(100)
local result = exec("1f")
assert(result.success or result == true, "MovePlayhead should succeed")
assert(seeked_frame == 101,
    string.format("Expected seek to 101, got %s", tostring(seeked_frame)))
-- Jog audio fires on transport.engine_for_target(); not exercised here.
-- Covered by 017 transport tests that bootstrap the transport singletons.
local _ = audio_frame

-- Test 2: "-1f" from position 100 → seeks to 99
print("Test 2: -1f backward from 100")
reset(100)
exec("-1f")
assert(seeked_frame == 99,
    string.format("Expected seek to 99, got %s", tostring(seeked_frame)))

-- Test 3: "1s" at 24fps from position 100 → seeks to 124
print("Test 3: 1s at 24fps from 100")
reset(100)
exec("1s")
assert(seeked_frame == 124,
    string.format("Expected seek to 124, got %s", tostring(seeked_frame)))

-- Test 4: "-1s" at 24fps from position 100 → seeks to 76
print("Test 4: -1s at 24fps from 100")
reset(100)
exec("-1s")
assert(seeked_frame == 76,
    string.format("Expected seek to 76, got %s", tostring(seeked_frame)))

-- Test 5: "30f" from position 0 → seeks to 30
print("Test 5: 30f from 0")
reset(0)
exec("30f")
assert(seeked_frame == 30,
    string.format("Expected seek to 30, got %s", tostring(seeked_frame)))

-- Test 6: Clamp: "-200f" from position 100 → seeks to 0 (not -100)
print("Test 6: clamp -200f from 100 to 0")
reset(100)
exec("-200f")
assert(seeked_frame == 0,
    string.format("Expected seek to 0 (clamped), got %s", tostring(seeked_frame)))

-- Test 7: Missing positional arg → error
print("Test 7: missing positional arg errors")
reset(100)
local r7 = command_manager.execute("MovePlayhead", { _positional = {}, project_id = "proj" })
assert(not r7.success, "Expected failure for missing positional arg")

-- Test 8: Invalid literal "abc" → error
print("Test 8: invalid literal 'abc' errors")
reset(100)
local r8 = command_manager.execute("MovePlayhead", { _positional = {"abc"}, project_id = "proj" })
assert(not r8.success, "Expected failure for invalid literal 'abc'")

-- Test 9: Unknown unit "1x" → error
print("Test 9: unknown unit '1x' errors")
reset(100)
local r9 = command_manager.execute("MovePlayhead", { _positional = {"1x"}, project_id = "proj" })
assert(not r9.success, "Expected failure for unknown unit '1x'")

print("✅ test_move_playhead_command.lua passed")
