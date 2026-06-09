#!/usr/bin/env luajit

-- Regression: when a user invokes an active-record edit command from a
-- shortcut, menu, or any other UI surface that calls execute_interactive
-- without explicitly passing a playhead, the command must receive the
-- playhead from the active sequence's authoritative position.
--
-- This was broken for ACTIVE-RECORD commands (those that declare
-- sequence_id.required = true). The framework injected sequence_id but
-- short-circuited before injecting playhead — so e.g. pressing E
-- (ExtendEdit) silently failed with "missing required param 'playhead'".
--
-- Domain behavior under test (no implementation references):
--   When the user invokes an edit command that needs the playhead, and
--   the playhead is not explicitly supplied, the command receives the
--   playhead the user currently sees in the active record sequence.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local registry        = require("core.command_registry")

print("=== test_active_record_playhead_injection.lua ===")

local DB = "/tmp/jve/test_active_record_playhead_injection.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))

-- Active record sequence has its persisted playhead at frame 240.
local EXPECTED_PLAYHEAD = 240
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence',
        24, 1, 48000, 1920, 1080, %d, %d, %d)
]], EXPECTED_PLAYHEAD, now, now))

command_manager.init("seq", "proj")

-- Sanity: confirm the fixture wrote the playhead column we expect.
do
    local Sequence = require("models.sequence")
    local row = assert(Sequence.find("seq"), "fixture: sequence row missing")
    assert(row.playhead_position == EXPECTED_PLAYHEAD, string.format(
        "fixture: expected sequence.playhead_position=%d, got %s",
        EXPECTED_PLAYHEAD, tostring(row.playhead_position)))
end

-- Register a synthetic active-record probe command. Declares both
-- sequence_id (required → ACTIVE-RECORD routing) and playhead (required).
-- The executor merely captures what it was handed so the test can assert
-- on auto-injection without touching any real edit subsystem.
local captured_args = nil
registry.register_executor("TestProbeActiveRecord",
    function(command)
        captured_args = command:get_all_parameters()
        return true
    end,
    function() return true end,  -- undoer (unused: undoable=false)
    {
        undoable = false,
        args = {
            project_id  = { required = true },
            sequence_id = { required = true, kind = "string" },
            playhead    = { required = true, kind = "number" },
        },
    })

-- Caller supplies only project_id — sequence_id and playhead must be
-- auto-injected from the framework.
local result = command_manager.execute_interactive("TestProbeActiveRecord", {
    project_id = "proj",
})

assert(result and result.success, string.format(
    "command must succeed; got %s",
    tostring(result and result.error_message or "no result")))
assert(captured_args, "executor was not invoked")
assert(captured_args.sequence_id == "seq", string.format(
    "sequence_id auto-injection failed: got %s", tostring(captured_args.sequence_id)))
assert(captured_args.playhead == EXPECTED_PLAYHEAD, string.format(
    "playhead auto-injection failed: expected %d, got %s",
    EXPECTED_PLAYHEAD, tostring(captured_args.playhead)))

print("  ok — sequence_id and playhead auto-injected for active-record command")

print("\n✅ test_active_record_playhead_injection.lua passed")
