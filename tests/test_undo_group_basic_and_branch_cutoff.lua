#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")

----------------------------------------------------------------
-- Test: Undo grouping is atomic and branch-safe
--
-- Invariants tested:
-- 1. Multiple commands inside begin/end undo group collapse to one undo step
-- 2. Redo is unavailable until an undo occurs
-- 3. Undo reverts the entire group at once
-- 4. Redo reapplies the entire group at once
-- 5. Undo + new command creates a branch
-- 6. Redo must NOT cross branches to reapply a prior undo group
----------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_undo_group_basic_and_branch_cutoff.db"

-- Minimal valid layout: empty timeline is sufficient
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips   = {}
})

local cm = command_manager

----------------------------------------------------------------
-- Initial state sanity
----------------------------------------------------------------

assert(
    cm.can_undo() == false,
    "Initial state: can_undo() must be false before any commands execute"
)

assert(
    cm.can_redo() == false,
    "Initial state: can_redo() must be false before any undo occurs"
)

----------------------------------------------------------------
-- Grouped commands collapse into one undo
----------------------------------------------------------------

cm.begin_undo_group("group1")

cm.execute("InsertGap", {
    project_id  = "proj",
    sequence_id = layout.sequence_id,
    position    = 0,
    duration    = 10,
})

cm.execute("InsertGap", {
    project_id  = "proj",
    sequence_id = layout.sequence_id,
    position    = 10,
    duration    = 5,
})

cm.end_undo_group()

-- can_undo becomes true because end_undo_group establishes a commit boundary
assert(
    cm.can_undo() == true,
    "After closing undo group with executed commands, can_undo() must be true"
)

assert(
    cm.can_redo() == false,
    "After command execution (no undo yet), can_redo() must be false"
)

----------------------------------------------------------------
-- Undo: both commands undone at once
----------------------------------------------------------------

local undo_result = cm.undo()

assert(
    undo_result.success == true,
    "Undo of grouped commands must succeed"
)

assert(
    cm.can_undo() == false,
    "After undoing the only undo group, can_undo() must be false"
)

assert(
    cm.can_redo() == true,
    "After undoing a group, can_redo() must be true"
)

----------------------------------------------------------------
-- Redo: both commands redone at once
----------------------------------------------------------------

local redo_result = cm.redo()

assert(
    redo_result.success == true,
    "Redo of grouped commands must succeed"
)

assert(
    cm.can_redo() == false,
    "After redoing the only undo group, can_redo() must be false"
)

assert(
    cm.can_undo() == true,
    "After redo, can_undo() must be true"
)

----------------------------------------------------------------
-- Undo again to create a branch point
----------------------------------------------------------------

undo_result = cm.undo()

assert(
    undo_result.success == true,
    "Second undo of grouped commands must succeed"
)

assert(
    cm.can_redo() == true,
    "After undo, redo must be available before branching"
)

----------------------------------------------------------------
-- Execute new command (branch cut)
----------------------------------------------------------------

cm.execute("InsertGap", {
    project_id  = "proj",
    sequence_id = layout.sequence_id,
    position    = 0,
    duration    = 3,
})

----------------------------------------------------------------
-- Redo must now be impossible (branch-safe behavior)
----------------------------------------------------------------

local redo_after_branch = cm.redo()

assert(
    redo_after_branch.success == false,
    "Redo must fail after branching: redo cannot cross branch boundaries to reapply an undo group"
)

----------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------

layout:cleanup()

print("✅ Undo grouping is atomic and branch-safe")
