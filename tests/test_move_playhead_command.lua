#!/usr/bin/env luajit

-- Test MovePlayhead command: duration-literal based playhead movement

require('test_env')

-- ── Mock panel_manager ──────────────────────────────────────────────────────
local current_frame = 100
local seeked_frame = nil
local audio_frame = nil

local mock_engine = {
    fps_num = 24, fps_den = 1,
    get_position = function(self) return current_frame end,
    play_frame_audio = function(self, f) audio_frame = f end,
}

local mock_sv = {
    sequence_id = "test_seq",
    engine = mock_engine,
    seek_to_frame = function(self, f) seeked_frame = f end,
}

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return mock_sv end,
}

-- ── Load the command module ─────────────────────────────────────────────────
local move_playhead = require("core.commands.move_playhead")
local reg = move_playhead.register({}, {}, nil)
local executor = reg.executor

-- ── Mock command object ─────────────────────────────────────────────────────
local function make_command(positional)
    return {
        get_all_parameters = function()
            return { _positional = positional }
        end,
    }
end

-- Reset helper
local function reset(frame, fps_num, fps_den)
    current_frame = frame or 100
    seeked_frame = nil
    audio_frame = nil
    mock_engine.fps_num = fps_num or 24
    mock_engine.fps_den = fps_den or 1
    mock_sv.sequence_id = "test_seq"
end

print("=== MovePlayhead Command Tests ===")

-- Test 1: "1f" from position 100 → seeks to 101
print("Test 1: 1f forward from 100")
reset(100)
executor(make_command({"1f"}))
assert(seeked_frame == 101,
    string.format("Expected seek to 101, got %s", tostring(seeked_frame)))
assert(audio_frame == 101,
    string.format("Expected audio at 101, got %s", tostring(audio_frame)))

-- Test 2: "-1f" from position 100 → seeks to 99
print("Test 2: -1f backward from 100")
reset(100)
executor(make_command({"-1f"}))
assert(seeked_frame == 99,
    string.format("Expected seek to 99, got %s", tostring(seeked_frame)))
assert(audio_frame == 99,
    string.format("Expected audio at 99, got %s", tostring(audio_frame)))

-- Test 3: "1s" at 24fps from position 100 → seeks to 124
print("Test 3: 1s at 24fps from 100")
reset(100, 24, 1)
executor(make_command({"1s"}))
assert(seeked_frame == 124,
    string.format("Expected seek to 124, got %s", tostring(seeked_frame)))
assert(audio_frame == 124,
    string.format("Expected audio at 124, got %s", tostring(audio_frame)))

-- Test 4: "-1s" at 24fps from position 100 → seeks to 76
print("Test 4: -1s at 24fps from 100")
reset(100, 24, 1)
executor(make_command({"-1s"}))
assert(seeked_frame == 76,
    string.format("Expected seek to 76, got %s", tostring(seeked_frame)))
assert(audio_frame == 76,
    string.format("Expected audio at 76, got %s", tostring(audio_frame)))

-- Test 5: "30f" from position 0 → seeks to 30
print("Test 5: 30f from 0")
reset(0)
executor(make_command({"30f"}))
assert(seeked_frame == 30,
    string.format("Expected seek to 30, got %s", tostring(seeked_frame)))

-- Test 6: Clamp: "-200f" from position 100 → seeks to 0 (not -100)
print("Test 6: clamp -200f from 100 to 0")
reset(100)
executor(make_command({"-200f"}))
assert(seeked_frame == 0,
    string.format("Expected seek to 0 (clamped), got %s", tostring(seeked_frame)))
assert(audio_frame == 0,
    string.format("Expected audio at 0 (clamped), got %s", tostring(audio_frame)))

-- Test 7: Missing positional arg → asserts
print("Test 7: missing positional arg asserts")
reset(100)
local ok7, err7 = pcall(executor, make_command({}))
assert(not ok7, "Expected error for missing positional arg")
assert(tostring(err7):find("duration literal required"),
    "Error should mention 'duration literal required', got: " .. tostring(err7))

-- Test 8: Invalid literal "abc" → asserts
print("Test 8: invalid literal 'abc' asserts")
reset(100)
local ok8, err8 = pcall(executor, make_command({"abc"}))
assert(not ok8, "Expected error for invalid literal 'abc'")
assert(tostring(err8):find("malformed duration literal"),
    "Error should mention 'malformed duration literal', got: " .. tostring(err8))

-- Test 9: Unknown unit "1x" → asserts
print("Test 9: unknown unit '1x' asserts")
reset(100)
local ok9, err9 = pcall(executor, make_command({"1x"}))
assert(not ok9, "Expected error for unknown unit '1x'")
assert(tostring(err9):find("unknown duration unit"),
    "Error should mention 'unknown duration unit', got: " .. tostring(err9))

-- Test 10: No sequence loaded → asserts
print("Test 10: no sequence loaded asserts")
reset(100)
mock_sv.sequence_id = nil
local ok10, err10 = pcall(executor, make_command({"1f"}))
assert(not ok10, "Expected error when no sequence loaded")
assert(tostring(err10):find("no sequence loaded"),
    "Error should mention 'no sequence loaded', got: " .. tostring(err10))
mock_sv.sequence_id = "test_seq"

print("✅ test_move_playhead_command.lua passed")
