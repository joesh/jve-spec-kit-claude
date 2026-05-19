#!/usr/bin/env luajit

-- Regression: roll/ripple on audio clips must convert delta_frames from
-- timeline frames to source samples when updating source_in/source_out.
--
-- Bug: apply_edge_ripple does source_in += delta_frames, but delta_frames
-- is in timeline frames (25fps) while audio source_in is in samples (48000).
-- The correct conversion is: source_delta = delta_frames * clip_rate / seq_rate.

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- =========================================================================
-- Setup: audio clip at 48000 samples/sec, sequence at 25fps
-- =========================================================================

local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1
local AUDIO_RATE = 48000  -- samples/sec (used as fps_numerator for audio)

-- Source_in at 1 second = 48000 samples. Non-trivial value to catch bugs.
local AUDIO_SOURCE_IN = 48000
-- Duration = 100 timeline frames = 4 seconds = 192000 samples
local TIMELINE_DURATION = 100

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_roll_audio_source_units.db",
    fps_numerator = SEQ_FPS_NUM,
    fps_denominator = SEQ_FPS_DEN,
    tracks = {
        order = {"a1"},
        a1 = {id = "track_a1", name = "A1", track_type = "AUDIO", track_index = 1, enabled = 1},
    },
    media = {
        order = {"main"},
        main = {
            id = "media_primary",
            name = "Audio",
            file_path = "synthetic://audio",
            duration_frames = 48000 * 600,  -- 10 minutes in samples
            fps_numerator = AUDIO_RATE,
            fps_denominator = 1,
            width = 0, height = 0,
            audio_channels = 2,
            codec = "pcm",
            metadata = "{}",
        },
    },
    clips = {
        order = {"clip_left", "clip_right", "clip_downstream"},
        clip_left = {
            id = "clip_left", name = "Left", track_key = "a1", media_key = "main",
            sequence_start = 0, duration = TIMELINE_DURATION,
            source_in = AUDIO_SOURCE_IN,
            fps_numerator = AUDIO_RATE,
            fps_denominator = 1,
        },
        clip_right = {
            id = "clip_right", name = "Right", track_key = "a1", media_key = "main",
            sequence_start = TIMELINE_DURATION, duration = TIMELINE_DURATION,
            source_in = AUDIO_SOURCE_IN + 192000,  -- offset by 4 seconds of samples
            fps_numerator = AUDIO_RATE,
            fps_denominator = 1,
        },
        clip_downstream = {
            id = "clip_downstream", name = "Downstream", track_key = "a1", media_key = "main",
            sequence_start = TIMELINE_DURATION * 2, duration = TIMELINE_DURATION,
            source_in = AUDIO_SOURCE_IN + 384000,
            fps_numerator = AUDIO_RATE,
            fps_denominator = 1,
        },
    },
})

-- =========================================================================
-- Capture before-state
-- =========================================================================

local left_before = Clip.load("clip_left")
local right_before = Clip.load("clip_right")
local ds_before = Clip.load("clip_downstream")

assert(left_before.source_in == AUDIO_SOURCE_IN,
    "setup: left source_in should be " .. AUDIO_SOURCE_IN)
assert(left_before.duration == TIMELINE_DURATION,
    "setup: left duration should be " .. TIMELINE_DURATION)

-- =========================================================================
-- Test 1: Roll extends left clip, trims right clip's in-point
--         source_in must change in SAMPLES, not timeline frames
-- =========================================================================

local DELTA_FRAMES = 10  -- 10 timeline frames at 25fps = 0.4 seconds
-- Expected source delta = 10 * (48000/1) / (25/1) = 19200 samples
local EXPECTED_SOURCE_DELTA = DELTA_FRAMES * AUDIO_RATE / SEQ_FPS_NUM

local roll_cmd = Command.create("BatchRippleEdit", layout.project_id)
roll_cmd:set_parameter("sequence_id", layout.sequence_id)
roll_cmd:set_parameter("edge_infos", {
    {clip_id = "clip_left", edge_type = "out", track_id = "track_a1", trim_type = "roll"},
    {clip_id = "clip_right", edge_type = "in", track_id = "track_a1", trim_type = "roll"},
})
roll_cmd:set_parameter("delta_frames", DELTA_FRAMES)

local result = command_manager.execute(roll_cmd)
assert(result.success, "Roll failed: " .. tostring(result.error_message))

-- Verify timeline coordinates (these should be correct regardless of unit bug)
local left_after = Clip.load("clip_left")
local right_after = Clip.load("clip_right")
local ds_after = Clip.load("clip_downstream")

assert(left_after.duration == TIMELINE_DURATION + DELTA_FRAMES,
    string.format("Left duration: expected %d, got %d",
        TIMELINE_DURATION + DELTA_FRAMES, left_after.duration))

assert(right_after.sequence_start == TIMELINE_DURATION + DELTA_FRAMES,
    string.format("Right start: expected %d, got %d",
        TIMELINE_DURATION + DELTA_FRAMES, right_after.sequence_start))

assert(right_after.duration == TIMELINE_DURATION - DELTA_FRAMES,
    string.format("Right duration: expected %d, got %d",
        TIMELINE_DURATION - DELTA_FRAMES, right_after.duration))

assert(ds_after.sequence_start == ds_before.sequence_start,
    "Downstream must not shift (roll, not ripple)")

-- THE CRITICAL ASSERTION: source_in must change by samples, not frames
local actual_source_delta = right_after.source_in - right_before.source_in
assert(actual_source_delta == EXPECTED_SOURCE_DELTA,
    string.format(
        "UNIT MISMATCH: right clip source_in changed by %d, expected %d (delta_frames=%d, "
        .. "clip_rate=%d, seq_rate=%d). source_in went from %d to %d",
        actual_source_delta, EXPECTED_SOURCE_DELTA, DELTA_FRAMES,
        AUDIO_RATE, SEQ_FPS_NUM,
        right_before.source_in, right_after.source_in))

-- In-edge trim: source_out must NOT change (we moved the left edge, right stays)
assert(right_after.source_out == right_before.source_out,
    string.format(
        "IN-EDGE TRIM: source_out should not change. before=%d after=%d",
        right_before.source_out, right_after.source_out))

-- =========================================================================
-- Test 2: Undo restores exact source coordinates
-- =========================================================================

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo failed")

local right_restored = Clip.load("clip_right")
assert(right_restored.source_in == right_before.source_in,
    string.format("Undo didn't restore source_in: expected %d, got %d",
        right_before.source_in, right_restored.source_in))
assert(right_restored.source_out == right_before.source_out,
    string.format("Undo didn't restore source_out: expected %d, got %d",
        right_before.source_out, right_restored.source_out))

-- =========================================================================
-- Test 3: Ripple on audio clip also needs correct source_in conversion
-- =========================================================================

local rip_cmd = Command.create("BatchRippleEdit", layout.project_id)
rip_cmd:set_parameter("sequence_id", layout.sequence_id)
rip_cmd:set_parameter("edge_infos", {
    {clip_id = "clip_right", edge_type = "in", track_id = "track_a1", trim_type = "ripple"},
})
rip_cmd:set_parameter("delta_frames", DELTA_FRAMES)

local rip_result = command_manager.execute(rip_cmd)
assert(rip_result.success, "Ripple failed: " .. tostring(rip_result.error_message))

local right_rippled = Clip.load("clip_right")
local ripple_source_delta = right_rippled.source_in - right_before.source_in
assert(ripple_source_delta == EXPECTED_SOURCE_DELTA,
    string.format(
        "RIPPLE UNIT MISMATCH: source_in changed by %d, expected %d",
        ripple_source_delta, EXPECTED_SOURCE_DELTA))

-- In-edge ripple: source_out must not change
assert(right_rippled.source_out == right_before.source_out,
    string.format(
        "RIPPLE IN-EDGE: source_out should not change. before=%d after=%d",
        right_before.source_out, right_rippled.source_out))

command_manager.undo()

layout:cleanup()
print("✅ test_roll_audio_source_units.lua passed")
