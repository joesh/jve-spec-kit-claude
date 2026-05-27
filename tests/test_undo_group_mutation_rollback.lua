#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local ripple_layout   = require("tests.helpers.ripple_layout")

----------------------------------------------------------------
-- Test: Undo group failure rolls back in-memory mutations
--
-- Regression test for: partial undo group success causes DB/in-memory
-- divergence. When command 1 succeeds (applying mutations) and
-- command 2 fails (triggering DB ROLLBACK TO SAVEPOINT), in-memory
-- clip state must also be restored to pre-group state.
--
-- Without mutation rollback:
-- - DB is rolled back (clip at original position)
-- - In-memory state still shows clip moved
-- - Quit+reload reveals the divergence
--
-- Invariants tested:
-- 1. In-memory clip positions match pre-group state after rollback
-- 2. Subsequent commands in an aborted group are rejected
-- 3. System remains usable after rollback
----------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_undo_group_mutation_rollback.db"

local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_a", "v1_b"},
        v1_a = {
            id = "clip_a",
            track_key = "v1",
            sequence_start = 100,
            duration = 500,
            source_in = 1000,
        },
        v1_b = {
            id = "clip_b",
            track_key = "v1",
            sequence_start = 700,
            duration = 300,
            source_in = 2000,
        },
    }
})

local cm = command_manager

----------------------------------------------------------------
-- Capture pre-group in-memory state
----------------------------------------------------------------

local clip_a_before = timeline_state.get_tab_strip():clip_by_id("clip_a")
assert(clip_a_before, "clip_a must exist in timeline_state")
assert(clip_a_before.sequence_start == 100,
    string.format("clip_a initial start must be 100, got %s", tostring(clip_a_before.sequence_start)))

local clip_b_before = timeline_state.get_tab_strip():clip_by_id("clip_b")
assert(clip_b_before, "clip_b must exist in timeline_state")
assert(clip_b_before.sequence_start == 700,
    string.format("clip_b initial start must be 700, got %s", tostring(clip_b_before.sequence_start)))

----------------------------------------------------------------
-- Undo group: succeed on first command, fail on second
----------------------------------------------------------------

cm.begin_undo_group("mutation_rollback_test")

-- Command 1: Nudge clip_a forward by 50 frames (succeeds, applies mutations)
local nudge_result = cm.execute("Nudge", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    nudge_amount = 50,
    selected_clip_ids = {"clip_a"},
})
assert(nudge_result.success, "Nudge must succeed: " .. tostring(nudge_result.error_message))

-- Verify in-memory mutation was applied (clip_a moved)
local clip_a_mid = timeline_state.get_tab_strip():clip_by_id("clip_a")
assert(clip_a_mid.sequence_start == 150,
    string.format("After nudge, clip_a should be at 150, got %s", tostring(clip_a_mid.sequence_start)))

-- Command 2: Force a failure (nonexistent clip ID in MoveClipToTrack)
local asserts = require("core.asserts")
asserts._set_enabled_for_tests(false)
local fail_result = cm.execute("MoveClipToTrack", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    clip_id = "nonexistent_clip_id_xyz",
    target_track_id = "track_v2",
})
asserts._set_enabled_for_tests(true)

assert(fail_result.success == false,
    "MoveClipToTrack with nonexistent clip must fail")

cm.end_undo_group()

----------------------------------------------------------------
-- Verify: in-memory state restored to pre-group state
----------------------------------------------------------------

local clip_a_after = timeline_state.get_tab_strip():clip_by_id("clip_a")
assert(clip_a_after, "clip_a must still exist after rollback")
assert(clip_a_after.sequence_start == 100,
    string.format(
        "MUTATION ROLLBACK: clip_a must be at original 100 after group failure, got %s (DB/memory divergence!)",
        tostring(clip_a_after.sequence_start)))

local clip_b_after = timeline_state.get_tab_strip():clip_by_id("clip_b")
assert(clip_b_after, "clip_b must still exist after rollback")
assert(clip_b_after.sequence_start == 700,
    string.format("clip_b must remain at 700 after group failure, got %s", tostring(clip_b_after.sequence_start)))

----------------------------------------------------------------
-- Verify: history cursor not advanced, no undoable commands
----------------------------------------------------------------

assert(cm.can_undo() == false,
    "can_undo() must be false after undo group failure (atomic rollback)")

assert(cm.can_redo() == false,
    "can_redo() must be false after undo group failure")

----------------------------------------------------------------
-- Verify: system usable after rollback
----------------------------------------------------------------

local post_result = cm.execute("Nudge", {
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
    nudge_amount = 25,
    selected_clip_ids = {"clip_b"},
})
assert(post_result.success, "Command after rollback must succeed: " .. tostring(post_result.error_message))

local clip_b_post = timeline_state.get_tab_strip():clip_by_id("clip_b")
assert(clip_b_post.sequence_start == 725,
    string.format("clip_b should be at 725 after post-rollback nudge, got %s", tostring(clip_b_post.sequence_start)))

assert(cm.can_undo() == true, "can_undo() must be true after post-rollback command")

-- Undo and verify
local undo_result = cm.undo()
assert(undo_result.success, "Undo after rollback must succeed")

local clip_b_undone = timeline_state.get_tab_strip():clip_by_id("clip_b")
assert(clip_b_undone.sequence_start == 700,
    string.format("clip_b must return to 700 after undo, got %s", tostring(clip_b_undone.sequence_start)))

----------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------

layout:cleanup()

print("✅ test_undo_group_mutation_rollback.lua passed")
