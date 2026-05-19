#!/usr/bin/env luajit

-- Regression: overwrite on audio tracks must convert timeline-frame trims
-- to source samples when computing occluded clip source coordinates.
--
-- Tests clip_mutator.resolve_occlusions with audio clips where
-- clip.fps_numerator=48000 (samples) vs sequence fps=25.

require("test_env")

local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1
local AUDIO_RATE = 48000

-- Existing clip: 200 frames long (8 seconds), source at 3 seconds
local EXISTING_SOURCE_IN = 48000 * 3   -- 144000 samples
local EXISTING_DURATION = 200          -- timeline frames
-- source_out = source_in + duration_in_samples = 144000 + 200 * 1920 = 144000 + 384000 = 528000
local EXISTING_SOURCE_OUT = EXISTING_SOURCE_IN + EXISTING_DURATION * (AUDIO_RATE / SEQ_FPS_NUM)

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_overwrite_audio_source.db",
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
        order = {"existing"},
        existing = {
            id = "clip_existing", name = "Existing", track_key = "a1", media_key = "main",
            sequence_start = 0, duration = EXISTING_DURATION,
            source_in = EXISTING_SOURCE_IN,
            fps_numerator = AUDIO_RATE, fps_denominator = 1,
        },
    },
})

-- Fix source_out to correct value
local db = layout.db
local fix = db:prepare("UPDATE clips SET source_out_frame = ? WHERE id = ?")
fix:bind_value(1, EXISTING_SOURCE_OUT)
fix:bind_value(2, "clip_existing")
assert(fix:exec())
fix:finalize()

-- Verify setup
local before = Clip.load("clip_existing")
assert(before.sequence_start == 0)
assert(before.duration == EXISTING_DURATION)
assert(before.source_in == EXISTING_SOURCE_IN)
assert(before.source_out == EXISTING_SOURCE_OUT,
    string.format("setup: source_out expected %d, got %d", EXISTING_SOURCE_OUT, before.source_out))

-- =========================================================================
-- Test: Overwrite covers the HEAD of the existing clip (trim left side)
-- An overwrite at [0, 50] should trim existing clip to [50, 200].
-- source_in should advance by 50 * 1920 = 96000 samples.
-- source_out should NOT change (right edge stays).
-- =========================================================================

local OVERWRITE_END = 50  -- timeline frames
local EXPECTED_SOURCE_DELTA = OVERWRITE_END * AUDIO_RATE / SEQ_FPS_NUM  -- 96000 samples

-- Call resolve_occlusions directly since Overwrite command has complex setup
local clip_mutator = require("core.clip_mutator")

local ok, err, actions = clip_mutator.resolve_occlusions(db, {
    track_id = "track_a1",
    sequence_start = 0,
    duration = OVERWRITE_END,
    exclude_clip_id = "clip_overwrite",
})

assert(ok, "resolve_occlusions failed: " .. tostring(err))
assert(#actions > 0, "resolve_occlusions should produce at least one action")

-- Find the update action for our clip
-- Actions use flat structure: {type, clip_id, source_in_frame, source_out_frame, ...}
local update_action = nil
for _, action in ipairs(actions) do
    if action.type == "update" and action.clip_id == "clip_existing" then
        update_action = action
        break
    end
end

assert(update_action, "No update action found for clip_existing")

assert(update_action.sequence_start_frame == OVERWRITE_END,
    string.format("Trimmed start: expected %d, got %d",
        OVERWRITE_END, update_action.sequence_start_frame))
assert(update_action.duration_frames == EXISTING_DURATION - OVERWRITE_END,
    string.format("Trimmed duration: expected %d, got %d",
        EXISTING_DURATION - OVERWRITE_END, update_action.duration_frames))

-- THE KEY ASSERTIONS: source coordinates
local source_in_delta = update_action.source_in_frame - EXISTING_SOURCE_IN
assert(source_in_delta == EXPECTED_SOURCE_DELTA,
    string.format(
        "HEAD TRIM UNIT MISMATCH: source_in changed by %d, expected %d "
        .. "(trim=%d frames, rate=%d, seq=%d). source_in: %d → %d",
        source_in_delta, EXPECTED_SOURCE_DELTA,
        OVERWRITE_END, AUDIO_RATE, SEQ_FPS_NUM,
        EXISTING_SOURCE_IN, update_action.source_in_frame))

-- source_out should NOT change (head trim keeps right edge)
assert(update_action.source_out_frame == EXISTING_SOURCE_OUT,
    string.format(
        "HEAD TRIM: source_out should not change. before=%d after=%d",
        EXISTING_SOURCE_OUT, update_action.source_out_frame))

-- =========================================================================
-- Test 2: Overwrite covers the TAIL (trim right side)
-- An overwrite at [150, 200] should trim existing clip to [0, 150].
-- source_in should NOT change (left edge stays).
-- source_out should decrease by (200-150) * 1920 = 96000 samples.
-- =========================================================================

local TAIL_START = 150
-- Tail trim = 50 frames; source delta = 50 * 48000 / 25 = 96000 samples

local ok2, err2, actions2 = clip_mutator.resolve_occlusions(db, {
    track_id = "track_a1",
    sequence_start = TAIL_START,
    duration = EXISTING_DURATION - TAIL_START,
    exclude_clip_id = "clip_overwrite2",
})

assert(ok2, "resolve_occlusions tail failed: " .. tostring(err2))

local tail_update = nil
for _, action in ipairs(actions2) do
    if action.type == "update" and action.clip_id == "clip_existing" then
        tail_update = action
        break
    end
end

assert(tail_update, "No tail update action found")

assert(tail_update.duration_frames == TAIL_START,
    string.format("Tail trimmed duration: expected %d, got %d",
        TAIL_START, tail_update.duration_frames))

-- source_in should NOT change (right side trim)
assert(tail_update.source_in_frame == EXISTING_SOURCE_IN,
    string.format("TAIL TRIM: source_in should not change. before=%d after=%d",
        EXISTING_SOURCE_IN, tail_update.source_in_frame))

-- source_out should be source_in + new_duration_in_samples
local expected_tail_source_out = EXISTING_SOURCE_IN + TAIL_START * (AUDIO_RATE / SEQ_FPS_NUM)
assert(tail_update.source_out_frame == expected_tail_source_out,
    string.format(
        "TAIL TRIM UNIT MISMATCH: source_out=%d expected=%d "
        .. "(source_in=%d + %d frames * %d rate / %d seq)",
        tail_update.source_out_frame, expected_tail_source_out,
        EXISTING_SOURCE_IN, TAIL_START, AUDIO_RATE, SEQ_FPS_NUM))

layout:cleanup()
print("✅ test_overwrite_audio_source_units.lua passed")
