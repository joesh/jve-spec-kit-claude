#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")

----------------------------------------------------------------
-- Test: Undo group failure triggers SAVEPOINT rollback
--
-- Invariants tested:
-- 1. Commands inside undo group that succeed before a failure are rolled back
-- 2. can_undo() remains false after undo group fails
-- 3. History cursor does not advance when undo group fails
-- 4. Undo groups are atomic: all-or-nothing semantics under failure
--
-- SAVEPOINT semantics:
-- - begin_undo_group() creates SAVEPOINT
-- - Command failure triggers ROLLBACK TO SAVEPOINT
-- - No partial commits - either entire group succeeds or nothing commits
-- - This prevents corrupted undo history from partial group execution
----------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_undo_group_atomic_failure.db"

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

local initial_sequence_number = cm.get_current_sequence_number()

assert(
    initial_sequence_number == nil,
    "Initial state: sequence number should be nil (no commands executed)"
)

----------------------------------------------------------------
-- Undo group with failure: valid command + failing command
----------------------------------------------------------------

cm.begin_undo_group("atomic_failure_test")

-- Execute valid command (should succeed)
local valid_result = cm.execute("InsertGap", {
    sequence_id = layout.sequence_id,
    position    = 0,
    duration    = 10,
})

assert(
    valid_result.success == true,
    "First command in undo group must succeed before failure occurs"
)

-- Execute failing command (missing required parameter)
-- AddTrack requires track_type, omitting it should cause validation failure
local fail_result = cm.execute("AddTrack", {
    sequence_id = layout.sequence_id,
    -- Missing required parameter: track_type
})

assert(
    fail_result.success == false,
    "Second command must fail due to missing required parameter (track_type not provided)"
)

-- End undo group (should not commit anything due to failure)
cm.end_undo_group()

----------------------------------------------------------------
-- Verify atomic rollback: no commands should be undoable
----------------------------------------------------------------

assert(
    cm.can_undo() == false,
    "SAVEPOINT rollback semantics: can_undo() must be false after undo group failure (no partial commits)"
)

assert(
    cm.can_redo() == false,
    "After undo group failure, can_redo() must be false (nothing to redo)"
)

local final_sequence_number = cm.get_current_sequence_number()

assert(
    final_sequence_number == initial_sequence_number,
    "Atomic undo group semantics: history cursor must not advance when undo group fails (all-or-nothing)"
)

----------------------------------------------------------------
-- Verify system is still usable after rollback
----------------------------------------------------------------

-- Execute a command outside undo group to verify system state is clean
local recovery_result = cm.execute("InsertGap", {
    sequence_id = layout.sequence_id,
    position    = 0,
    duration    = 10,
})

assert(
    recovery_result.success == true,
    "System must remain operational after undo group rollback (SAVEPOINT cleanup succeeded)"
)

assert(
    cm.can_undo() == true,
    "After successful command execution post-rollback, can_undo() must be true"
)

-- Undo the recovery command to clean up
local undo_recovery = cm.undo()

assert(
    undo_recovery.success == true,
    "System must support undo after recovering from failed undo group"
)

----------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------

layout:cleanup()

print("✅ Undo group failure triggers atomic SAVEPOINT rollback (all-or-nothing)")
