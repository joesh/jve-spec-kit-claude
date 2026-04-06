#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")

------------------------------------------------------------------------
-- Test: CreateSequence boundary guard (T003)
--
-- FR-006: can_undo() returns false when the next undoable command is
-- CreateSequence for the active sequence. You can't undo the creation
-- of the sequence you're currently viewing.
--
-- But: CreateSequence IS undoable from a different context.
------------------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_per_sequence_undo_boundary.db"
local PROJECT_ID = "proj"
local SEQ_A_ID = "seq_a"

-- Create project + sequence A
local layout = ripple_layout.create({  -- luacheck: ignore 211
    db_path = TEST_DB,
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    sequence_name = "Sequence A",
    clips = { order = {} },
})

local cm = command_manager

------------------------------------------------------------------------
-- Execute 2 edits in A
------------------------------------------------------------------------
cm.activate_timeline_stack(SEQ_A_ID)

local r1 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 0,
    duration = 10,
})
assert(r1.success, "Edit 1 failed: " .. tostring(r1.error_message))

local r2 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 10,
    duration = 15,
})
assert(r2.success, "Edit 2 failed: " .. tostring(r2.error_message))

------------------------------------------------------------------------
-- Undo both edits — can_undo should become false
-- (next command would be CreateSequence for active sequence A)
------------------------------------------------------------------------
assert(cm.can_undo(), "can_undo should be true with 2 edits")

local u1 = cm.undo()
assert(u1.success, "Undo edit 2 failed")

assert(cm.can_undo(), "can_undo should be true with 1 edit remaining")

local u2 = cm.undo()
assert(u2.success, "Undo edit 1 failed")

-- Now: if CreateSequence for A was recorded as a project-level command,
-- can_undo should return false because undoing it would destroy our context.
-- NOTE: In the current test setup, CreateSequence is not in the command history
-- (the sequence was created directly via Sequence.create, not through command_manager).
-- This test will need to be updated once CreateSequence goes through command_manager.

-- For now, verify that with no more commands to undo, can_undo is false
assert(cm.can_undo() == false, "can_undo should be false after undoing all edits in A")

print("T003: CreateSequence boundary guard — PASSED (basic)")
print("  NOTE: Full boundary test requires CreateSequence through command_manager")

print("✅ test_per_sequence_undo_boundary.lua passed")
