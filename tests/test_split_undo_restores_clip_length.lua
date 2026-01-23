#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")
local timeline_state = require("ui.timeline.timeline_state")

----------------------------------------------------------------
-- Test: Split undo restores upstream clip length in memory
--
-- Regression: After undo, the database was correctly restored
-- but the in-memory timeline state was not updated because
-- clip_update_payload used wrong field names (duration vs
-- duration_value) that apply_mutations didn't recognize.
----------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_split_undo_restores_clip_length.db"

-- Create default layout (has clips on v1, v2, etc.)
local layout = ripple_layout.create({db_path = TEST_DB})

-- Get a clip to split from the default layout
local clip_to_split = layout.clips.v1_left or layout.clips.v1_middle
assert(clip_to_split, "Expected clip from default layout")

-- Get initial duration from in-memory state
local clip_id = clip_to_split.id
local clips_before = timeline_state.get_clips()
local clip_before = nil
for _, c in ipairs(clips_before) do
    if c.id == clip_id then
        clip_before = c
        break
    end
end

assert(clip_before, "clip should exist before split")
local original_duration = clip_before.duration.frames
assert(original_duration and original_duration > 10,
    string.format("Initial duration should be > 10 frames, got %s", tostring(original_duration)))

-- Calculate split point at middle of clip
local split_point = clip_before.timeline_start.frames + math.floor(original_duration / 2)

-- Execute SplitClip
local split_result = command_manager.execute("SplitClip", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    clip_id = clip_id,
    split_value = split_point,
})

assert(split_result.success, "SplitClip should succeed: " .. (split_result.error_message or ""))

-- Verify clip was split - original clip now has shorter duration
local clips_after_split = timeline_state.get_clips()
local clip_after_split = nil
for _, c in ipairs(clips_after_split) do
    if c.id == clip_id then
        clip_after_split = c
        break
    end
end

assert(clip_after_split, "clip should still exist after split")
local split_duration = clip_after_split.duration.frames
assert(split_duration < original_duration,
    string.format("After split, duration (%d) should be less than original (%d)",
        split_duration, original_duration))

-- Now undo the split
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed: " .. (undo_result.error_message or ""))

-- REGRESSION: The in-memory clip should have duration restored
local clips_after_undo = timeline_state.get_clips()
local clip_after_undo = nil
for _, c in ipairs(clips_after_undo) do
    if c.id == clip_id then
        clip_after_undo = c
        break
    end
end

assert(clip_after_undo, "clip should exist after undo")
assert(clip_after_undo.duration and clip_after_undo.duration.frames == original_duration,
    string.format("REGRESSION: After undo, in-memory duration should be restored to %d frames, got %s",
        original_duration, clip_after_undo.duration and clip_after_undo.duration.frames or "nil"))

-- Cleanup
layout:cleanup()

print("✅ Split undo restores upstream clip length in memory")
