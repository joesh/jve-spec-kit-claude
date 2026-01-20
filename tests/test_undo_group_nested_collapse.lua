#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")

----------------------------------------------------------------
-- Test: Nested undo groups collapse into outermost group (Emacs semantics)
--
-- Invariants tested:
-- 1. Nested begin/end undo group calls collapse into outermost group
-- 2. All commands in outer group (including those in nested groups) undo as one unit
-- 3. Single undo() reverses entire outer group (all 3 commands)
-- 4. Single redo() reapplies entire outer group (all 3 commands)
-- 5. Branch cutoff prevents redo after new command execution
--
-- Emacs-style semantics:
-- - Inner groups are transparent - they don't create separate undo boundaries
-- - Only the outermost group establishes an undoable unit
-- - This prevents "undo tree noise" from implementation details
----------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_undo_group_nested_collapse.db"

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
-- Nested undo groups: outer contains inner + 2 other commands
----------------------------------------------------------------

cm.begin_undo_group("outer")

cm.execute("InsertGap", {
    project_id  = "proj",
    sequence_id = layout.sequence_id,
    position    = 0,
    duration    = 10,
})

-- Begin nested group
cm.begin_undo_group("inner")

cm.execute("InsertGap", {
    project_id  = "proj",
    sequence_id = layout.sequence_id,
    position    = 10,
    duration    = 5,
})

-- End nested group
cm.end_undo_group()

cm.execute("InsertGap", {
    project_id  = "proj",
    sequence_id = layout.sequence_id,
    position    = 15,
    duration    = 3,
})

-- End outer group
cm.end_undo_group()

----------------------------------------------------------------
-- After closing outer group, undo should be available
----------------------------------------------------------------

assert(
    cm.can_undo() == true,
    "After closing outer undo group with nested groups, can_undo() must be true"
)

assert(
    cm.can_redo() == false,
    "After command execution (no undo yet), can_redo() must be false"
)

----------------------------------------------------------------
-- Single undo must reverse entire outer group (all 3 commands)
----------------------------------------------------------------

local undo_result = cm.undo()

assert(
    undo_result.success == true,
    "Emacs semantics: single undo() must reverse entire outer group (including nested inner group)"
)

assert(
    cm.can_undo() == false,
    "After undoing the only undo group, can_undo() must be false (all 3 commands undone)"
)

assert(
    cm.can_redo() == true,
    "After undoing a group, can_redo() must be true"
)

----------------------------------------------------------------
-- Single redo must reapply entire outer group (all 3 commands)
----------------------------------------------------------------

local redo_result = cm.redo()

assert(
    redo_result.success == true,
    "Emacs semantics: single redo() must reapply entire outer group (including nested inner group)"
)

assert(
    cm.can_redo() == false,
    "After redoing the only undo group, can_redo() must be false (all 3 commands redone)"
)

assert(
    cm.can_undo() == true,
    "After redo, can_undo() must be true"
)

----------------------------------------------------------------
-- Undo again to create branch point
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
    duration    = 7,
})

----------------------------------------------------------------
-- Redo must fail after branching (cannot cross branch boundaries)
----------------------------------------------------------------

local redo_after_branch = cm.redo()

assert(
    redo_after_branch.success == false,
    "Emacs semantics: redo must fail after branching - nested group collapse doesn't change branch safety"
)

----------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------

layout:cleanup()

print("✅ Nested undo groups collapse into outermost group (Emacs semantics)")
