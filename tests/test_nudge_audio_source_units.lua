#!/usr/bin/env luajit

-- Regression: nudge on audio clips must convert nudge_frames from timeline
-- frames to source samples when updating source_in/source_out.

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")

local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1
local AUDIO_RATE = 48000

-- source_in at 2 seconds = 96000 samples
local AUDIO_SOURCE_IN = 96000
local AUDIO_SOURCE_OUT = AUDIO_SOURCE_IN + 192000  -- 4 seconds of samples
local TIMELINE_DURATION = 100  -- 100 frames at 25fps = 4 seconds

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_nudge_audio_source.db",
    fps_numerator = SEQ_FPS_NUM,
    fps_denominator = SEQ_FPS_DEN,
    tracks = {
        order = {"a1"},
        a1 = {id = "track_a1", name = "A1", track_type = "AUDIO", track_index = 1, enabled = 1},
    },
    media = {
        order = {"main"},
        main = {
            id = "media_primary", name = "Audio", file_path = "synthetic://audio",
            duration_frames = 48000 * 600,
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
            width = 0, height = 0, audio_channels = 2, codec = "pcm", metadata = "{}",
        },
    },
    clips = {
        order = {"clip_a"},
        clip_a = {
            id = "clip_a", name = "A", track_key = "a1", media_key = "main",
            sequence_start = 50, duration = TIMELINE_DURATION,
            source_in = AUDIO_SOURCE_IN,
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
        },
    },
})

-- Fix source_out to match the correct source range (not the broken source_in + duration)
local db = layout.db
local fix = db:prepare("UPDATE clips SET source_out_frame = ? WHERE id = ?")
fix:bind_value(1, AUDIO_SOURCE_OUT)
fix:bind_value(2, "clip_a")
assert(fix:exec())
fix:finalize()

-- Stub timeline_state for nudge command
timeline_state.get_project_id = function() return layout.project_id end
timeline_state.get_sequence_id = function() return layout.sequence_id end
timeline_state.reload_clips = function() end
timeline_state.set_playhead_position = function() end
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 3000, timebase_type = "video_frames", timebase_rate = SEQ_FPS_NUM}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function() end
timeline_state.set_selection = function() end
timeline_state.set_edge_selection = function() end
timeline_state.set_gap_selection = function() end
timeline_state.get_sequence_frame_rate = function()
    return {fps_numerator = SEQ_FPS_NUM, fps_denominator = SEQ_FPS_DEN}
end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function() return true end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function()
    return {{clip_id = "clip_a", edge_type = "in", trim_type = "ripple"}}
end

local before = Clip.load("clip_a")
assert(before.source_in == AUDIO_SOURCE_IN)
assert(before.source_out == AUDIO_SOURCE_OUT)

-- =========================================================================
-- Test 1: Nudge in-edge by 5 timeline frames
-- =========================================================================

local NUDGE = 5  -- timeline frames
local EXPECTED_SOURCE_DELTA = NUDGE * AUDIO_RATE / SEQ_FPS_NUM  -- 5 * 1920 = 9600 samples

local cmd = Command.create("Nudge", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("nudge_amount", NUDGE)
cmd:set_parameter("selected_edges", {{clip_id = "clip_a", edge_type = "in", trim_type = "ripple"}})

local result = command_manager.execute(cmd)
assert(result.success, "NudgeEdge failed: " .. tostring(result.error_message))

local after = Clip.load("clip_a")

-- source_in should change by samples, not timeline frames
local actual_delta = after.source_in - before.source_in
assert(actual_delta == EXPECTED_SOURCE_DELTA,
    string.format(
        "NUDGE IN UNIT MISMATCH: source_in changed by %d, expected %d "
        .. "(nudge=%d frames, rate=%d, seq=%d)",
        actual_delta, EXPECTED_SOURCE_DELTA, NUDGE, AUDIO_RATE, SEQ_FPS_NUM))

-- source_out should NOT change (in-edge nudge)
assert(after.source_out == before.source_out,
    string.format("NUDGE IN: source_out should not change. before=%d after=%d",
        before.source_out, after.source_out))

command_manager.undo()

-- =========================================================================
-- Test 2: Nudge out-edge by 5 timeline frames
-- =========================================================================

timeline_state.get_selected_edges = function()
    return {{clip_id = "clip_a", edge_type = "out", trim_type = "ripple"}}
end

local cmd2 = Command.create("Nudge", layout.project_id)
cmd2:set_parameter("sequence_id", layout.sequence_id)
cmd2:set_parameter("nudge_amount", NUDGE)
cmd2:set_parameter("selected_edges", {{clip_id = "clip_a", edge_type = "out", trim_type = "ripple"}})

local result2 = command_manager.execute(cmd2)
assert(result2.success, "NudgeEdge out failed: " .. tostring(result2.error_message))

local after2 = Clip.load("clip_a")

-- source_in should NOT change (out-edge nudge)
assert(after2.source_in == before.source_in,
    string.format("NUDGE OUT: source_in should not change. before=%d after=%d",
        before.source_in, after2.source_in))

-- source_out should change by samples
local out_delta = after2.source_out - before.source_out
assert(out_delta == EXPECTED_SOURCE_DELTA,
    string.format(
        "NUDGE OUT UNIT MISMATCH: source_out changed by %d, expected %d",
        out_delta, EXPECTED_SOURCE_DELTA))

command_manager.undo()

layout:cleanup()
print("✅ test_nudge_audio_source_units.lua passed")
