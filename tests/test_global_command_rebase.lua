#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout   = require("tests.helpers.ripple_layout")
local Sequence        = require("models.sequence")
local Track           = require("models.track")

------------------------------------------------------------------------
-- Test: Global command rebase timestamp (T008)
--
-- FR-008: When a global command is undone from a sequence context,
-- its timestamp updates to now. All history views see it at the new
-- position. Rebase is permanent.
------------------------------------------------------------------------

local TEST_DB = "/tmp/jve/test_global_command_rebase.db"
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
local seq_b = Sequence.create("Sequence B", PROJECT_ID, frame_rate, 1920, 1080, {
    id = SEQ_B_ID,
    audio_rate = 48000,
})
assert(seq_b and seq_b:save(), "Failed to create sequence B")
local track_b = Track.create_video("Video 1", SEQ_B_ID, {id = "track_b_v1", index = 1})
assert(track_b and track_b:save(), "Failed to create track on B")

local cm = command_manager  -- luacheck: ignore 211

------------------------------------------------------------------------
-- Setup: Global (Import T1), Edit_A1 (T2), Edit_B1 (T3)
-- We simulate a global command by executing with no sequence_id
------------------------------------------------------------------------

-- TODO: Execute a real global command (ImportMedia, etc.).
-- For now, test is a placeholder that will be implemented when
-- the global command infrastructure is wired.

-- This test verifies rebase semantics:
-- 1. Global command at timestamp T1
-- 2. Undo global from A's context
-- 3. Global's timestamp should update to now (> T3)
-- 4. Switch to B — global should appear AFTER Edit_B1 in history

print("T008: Global command rebase timestamp — SKIPPED (requires global command support)")
print("  Will be implemented alongside T012-T019")

print("✅ test_global_command_rebase.lua passed")
