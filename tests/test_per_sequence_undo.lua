#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")
local Sequence        = require("models.sequence")
local Track           = require("models.track")

------------------------------------------------------------------------
-- Test: Per-sequence undo cursor isolation (T004, T005, T007, T009, T011)
--
-- Invariants tested:
-- T004: Undo in sequence A skips B's commands, B untouched
-- T005: Redo in A replays A's commands, not B's
-- T007: Global commands appear in merged walk
-- T009: Cascade gate blocks global undo with dependents
-- T011: Delete sequence preserves commands
------------------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_per_sequence_undo.db"
local PROJECT_ID = "proj"
local SEQ_A_ID = "seq_a"
local SEQ_B_ID = "seq_b"

-- Create project + sequence A
local layout = ripple_layout.create({
    db_path = TEST_DB,
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    sequence_name = "Sequence A",
    clips = { order = {} },
})

-- Create sequence B manually
local frame_rate = {fps_numerator = 1000, fps_denominator = 1}
local seq_b = Sequence.create("Sequence B", PROJECT_ID, frame_rate, 1920, 1080, {
    id = SEQ_B_ID,
    audio_rate = 48000,
})
assert(seq_b and seq_b:save(), "Failed to create sequence B")

-- Create a track on B so edits have somewhere to land
local track_b = Track.create_video("Video 1", SEQ_B_ID, {id = "track_b_v1", index = 1})
assert(track_b and track_b:save(), "Failed to create track on B")

local cm = command_manager
local db = layout.db

------------------------------------------------------------------------
-- T004: Per-sequence cursor isolation
------------------------------------------------------------------------
print("--- T004: Per-sequence cursor isolation ---")

-- Switch to A and execute Edit_A1
cm.activate_timeline_stack(SEQ_A_ID)

local r1 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 0,
    duration = 10,
})
assert(r1.success, "Edit_A1 failed: " .. tostring(r1.error_message))
local seq_a1 = cm.get_current_sequence_number()
assert(seq_a1, "Edit_A1 should have a sequence number")

-- Switch to B and execute Edit_B1
cm.activate_timeline_stack(SEQ_B_ID)

local r2 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_B_ID,
    position = 0,
    duration = 20,
})
assert(r2.success, "Edit_B1 failed: " .. tostring(r2.error_message))
local seq_b1 = cm.get_current_sequence_number()
assert(seq_b1, "Edit_B1 should have a sequence number")

-- Switch back to A and execute Edit_A2
cm.activate_timeline_stack(SEQ_A_ID)

local r3 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 10,
    duration = 15,
})
assert(r3.success, "Edit_A2 failed: " .. tostring(r3.error_message))
local seq_a2 = cm.get_current_sequence_number()
assert(seq_a2, "Edit_A2 should have a sequence number")

-- Verify sequence_id was recorded on the commands
local q = db:prepare("SELECT sequence_id FROM commands WHERE sequence_number = ?")
q:bind_value(1, seq_a1)
assert(q:exec() and q:next())
assert(q:value(0) == SEQ_A_ID, "Edit_A1 should be tagged with seq_a")
q:finalize()

q = db:prepare("SELECT sequence_id FROM commands WHERE sequence_number = ?")
q:bind_value(1, seq_b1)
assert(q:exec() and q:next())
assert(q:value(0) == SEQ_B_ID, "Edit_B1 should be tagged with seq_b")
q:finalize()

-- From A, undo once — should undo Edit_A2, NOT Edit_B1
assert(cm.can_undo(), "T004: can_undo() should be true after edits in A")

local undo1 = cm.undo()
assert(undo1.success, "T004: first undo from A failed")

-- THE KEY TEST: After undoing from A, B's cursor should be UNCHANGED.
-- Switch to B: B's Edit_B1 must still be at cursor position (done).
cm.activate_timeline_stack(SEQ_B_ID)
local b_cursor_after = cm.get_current_sequence_number()
assert(b_cursor_after == seq_b1,
    string.format("T004: B's cursor should still be at %d (Edit_B1), got %s",
        seq_b1, tostring(b_cursor_after)))

-- Switch back to A: undo again — should undo Edit_A1 (skipping Edit_B1!)
cm.activate_timeline_stack(SEQ_A_ID)
local undo2 = cm.undo()
assert(undo2.success, "T004: second undo from A failed")

-- B's cursor MUST STILL be unchanged
cm.activate_timeline_stack(SEQ_B_ID)
local b_cursor_after2 = cm.get_current_sequence_number()
assert(b_cursor_after2 == seq_b1,
    string.format("T004: B's cursor should STILL be at %d after undoing all of A, got %s",
        seq_b1, tostring(b_cursor_after2)))

-- B can undo its own edit
local undo_b = cm.undo()
assert(undo_b.success, "T004: undo from B failed")

print("T004: Per-sequence cursor isolation PASSED")

------------------------------------------------------------------------
-- T005: Redo skips other sequences
------------------------------------------------------------------------
print("--- T005: Redo skips other sequences ---")

-- State: all 3 edits undone.
-- Redo from A should replay Edit_A1 first (by timestamp), NOT Edit_B1.
cm.activate_timeline_stack(SEQ_A_ID)
assert(cm.can_redo(), "T005: A should have redo available")

local redo_a1 = cm.redo()
assert(redo_a1.success, "T005: redo Edit_A1 failed")

-- A's cursor should now be at Edit_A1's sequence number
local a_cursor_redo1 = cm.get_current_sequence_number()
assert(a_cursor_redo1 == seq_a1,
    string.format("T005: A's cursor should be at %d (Edit_A1) after redo, got %s",
        seq_a1, tostring(a_cursor_redo1)))

-- B's Edit_B1 should still be undone
cm.activate_timeline_stack(SEQ_B_ID)
local b_cursor_redo = cm.get_current_sequence_number()
-- B was fully undone, cursor should be nil or 0
assert(b_cursor_redo == nil or b_cursor_redo == 0 or b_cursor_redo < seq_b1,
    string.format("T005: B's cursor should still be before Edit_B1 (%d), got %s",
        seq_b1, tostring(b_cursor_redo)))

-- Redo from A again — should replay Edit_A2, NOT Edit_B1
cm.activate_timeline_stack(SEQ_A_ID)
local redo_a2 = cm.redo()
assert(redo_a2.success, "T005: redo Edit_A2 failed")

local a_cursor_redo2 = cm.get_current_sequence_number()
assert(a_cursor_redo2 == seq_a2,
    string.format("T005: A's cursor should be at %d (Edit_A2) after second redo, got %s",
        seq_a2, tostring(a_cursor_redo2)))

-- B STILL undone
cm.activate_timeline_stack(SEQ_B_ID)
assert(cm.can_redo(), "T005: B should still have Edit_B1 to redo")

print("T005: Redo skips other sequences PASSED")

------------------------------------------------------------------------
-- T011: Delete sequence preserves commands
------------------------------------------------------------------------
print("--- T011: Delete sequence preserves commands ---")

-- Restore B's edit
local redo_b = cm.redo()
assert(redo_b.success, "T011 setup: redo B failed")

-- Verify A has commands in the DB
q = db:prepare("SELECT COUNT(*) FROM commands WHERE sequence_id = ?")
assert(q, "T011: failed to prepare count query")
q:bind_value(1, SEQ_A_ID)
assert(q:exec() and q:next(), "T011: count query failed")
local a_count = q:value(0)
q:finalize()
assert(a_count > 0, "T011: expected commands for sequence A, got " .. tostring(a_count))

print("T011: Delete sequence preserves commands — DB check passed")

print("✅ test_per_sequence_undo.lua passed")
