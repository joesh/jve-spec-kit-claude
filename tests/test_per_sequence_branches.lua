#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")
local Sequence        = require("models.sequence")
local Track           = require("models.track")

------------------------------------------------------------------------
-- Test: Per-sequence branch isolation (T006)
--
-- FR-002: Each sequence has independent branch tracking.
-- A new command in A forks A's branch only — B's redo path is preserved.
------------------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_per_sequence_branches.db"
local PROJECT_ID = "proj"
local SEQ_A_ID = "seq_a"
local SEQ_B_ID = "seq_b"

-- Create project + sequence A
local layout = ripple_layout.create({  -- luacheck: ignore 211
    db_path = TEST_DB,
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    sequence_name = "Sequence A",
    clips = { order = {} },
})

-- Create sequence B
local frame_rate = {fps_numerator = 1000, fps_denominator = 1}
local seq_b = Sequence.create("Sequence B", PROJECT_ID, frame_rate, 1920, 1080, { kind = "nested", 
    id = SEQ_B_ID,
    audio_sample_rate = 48000,
})
assert(seq_b and seq_b:save(), "Failed to create sequence B")
local track_b = Track.create_video("Video 1", SEQ_B_ID, {id = "track_b_v1", index = 1})
assert(track_b and track_b:save(), "Failed to create track on B")

local cm = command_manager

------------------------------------------------------------------------
-- Setup: Edit_A1, Edit_B1
------------------------------------------------------------------------
cm.activate_timeline_stack(SEQ_A_ID)
local r1 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 0,
    duration = 10,
})
assert(r1.success, "Edit_A1 failed")

cm.activate_timeline_stack(SEQ_B_ID)
local r2 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_B_ID,
    position = 0,
    duration = 20,
})
assert(r2.success, "Edit_B1 failed")

------------------------------------------------------------------------
-- From A: undo Edit_A1, then execute Edit_A2_new (forks A's branch)
------------------------------------------------------------------------
cm.activate_timeline_stack(SEQ_A_ID)

local u1 = cm.undo()
assert(u1.success, "Undo Edit_A1 failed")

-- Execute a new command, forking A's branch
local r3 = cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 0,
    duration = 25,
})
assert(r3.success, "Edit_A2_new failed")

-- A's redo for Edit_A1 is lost (branched away)
assert(cm.can_redo() == false, "A should NOT be able to redo Edit_A1 (branched away)")

------------------------------------------------------------------------
-- Switch to B: Edit_B1 is still done AND B can still undo Edit_B1
-- B's branch is UNAFFECTED by A's fork
------------------------------------------------------------------------
cm.activate_timeline_stack(SEQ_B_ID)

assert(cm.can_undo(), "B should still be able to undo Edit_B1 (branch unaffected)")

local u_b = cm.undo()
assert(u_b.success, "Undo Edit_B1 failed")

-- B can redo Edit_B1 — its branch was not forked
assert(cm.can_redo(), "B should still be able to redo Edit_B1 (branch preserved)")

print("T006: Per-sequence branch isolation PASSED")

print("✅ test_per_sequence_branches.lua passed")
