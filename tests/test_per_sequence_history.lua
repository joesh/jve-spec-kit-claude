#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")
local Sequence        = require("models.sequence")
local Track           = require("models.track")

------------------------------------------------------------------------
-- Test: History view filtering per sequence (T010)
--
-- FR-009/010: History panel shows project-level + active sequence's
-- commands. B's commands are hidden when viewing A, and vice versa.
------------------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_per_sequence_history.db"
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
local seq_b = Sequence.create("Sequence B", PROJECT_ID, frame_rate, 1920, 1080, { kind = "sequence", 
    id = SEQ_B_ID,
    audio_sample_rate = 48000,
})
assert(seq_b and seq_b:save(), "Failed to create sequence B")
local track_b = Track.create_video("Video 1", SEQ_B_ID, {id = "track_b_v1", index = 1})
assert(track_b and track_b:save(), "Failed to create track on B")

local cm = command_manager

------------------------------------------------------------------------
-- Setup: interleaved commands
-- Edit_A1 (seq A), Edit_B1 (seq B), Edit_A2 (seq A)
------------------------------------------------------------------------
cm.activate_timeline_stack(SEQ_A_ID)
assert(cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 0,
    duration = 10,
}).success, "Edit_A1 failed")

cm.activate_timeline_stack(SEQ_B_ID)
assert(cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_B_ID,
    position = 0,
    duration = 20,
}).success, "Edit_B1 failed")

cm.activate_timeline_stack(SEQ_A_ID)
assert(cm.execute("InsertGap", {
    project_id = PROJECT_ID,
    sequence_id = SEQ_A_ID,
    position = 10,
    duration = 15,
}).success, "Edit_A2 failed")

------------------------------------------------------------------------
-- Query history for A: should see Edit_A1, Edit_A2 (no Edit_B1)
------------------------------------------------------------------------
cm.activate_timeline_stack(SEQ_A_ID)
local entries_a = cm:list_history_entries()
assert(type(entries_a) == "table", "list_history_entries should return a table")

-- Count sequence-scoped entries (exclude provenance/global)
local a_count = 0
for _, entry in ipairs(entries_a) do
    if entry.sequence_id == SEQ_A_ID then
        a_count = a_count + 1
    end
end

-- Should see 2 A commands, NOT B's command
assert(a_count == 2,
    string.format("T010: expected 2 entries for A, got %d", a_count))

-- Verify B's command is hidden
for _, entry in ipairs(entries_a) do
    assert(entry.sequence_id ~= SEQ_B_ID,
        "T010: B's command should NOT appear in A's history view")
end

------------------------------------------------------------------------
-- Query history for B: should see Edit_B1 only (no A commands)
------------------------------------------------------------------------
cm.activate_timeline_stack(SEQ_B_ID)
local entries_b = cm:list_history_entries()

local b_count = 0
for _, entry in ipairs(entries_b) do
    if entry.sequence_id == SEQ_B_ID then
        b_count = b_count + 1
    end
end

assert(b_count == 1,
    string.format("T010: expected 1 entry for B, got %d", b_count))

-- Verify A's commands are hidden
for _, entry in ipairs(entries_b) do
    assert(entry.sequence_id ~= SEQ_A_ID,
        "T010: A's commands should NOT appear in B's history view")
end

print("T010: History view filtering per sequence PASSED")

print("✅ test_per_sequence_history.lua passed")
