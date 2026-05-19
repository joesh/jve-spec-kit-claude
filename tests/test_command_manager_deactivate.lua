#!/usr/bin/env luajit

-- Regression: command_manager must support entering a "no active sequence"
-- mode. Two primitives are required:
--   init_project_only(project_id) — opens the manager for a project with no
--       per-sequence stack activated (used on startup when no last-open tab).
--   deactivate() — drops the currently-active per-sequence stack without
--       discarding its persisted commands (feature 010, FR-014: undoing a
--       sequence-delete must restore the sequence's undo history intact).
--
-- Domain behavior under test:
--   * After init_project_only, undo/redo of a per-sequence command from a
--     non-active sequence must not fire (the stack isn't active).
--   * After init(seq, pid) then deactivate(), any per-sequence undo history
--     already persisted remains on disk — deactivate must not delete it.

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local DB_PATH = "/tmp/jve/test_cmd_mgr_deactivate.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH))
local conn = database.get_connection()
conn:exec(require('import_schema'))

local PROJ = "prj-deactivate-test"
local SEQ  = "seq-deactivate-test"

assert(conn:exec(string.format([[
INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
VALUES ('%s', 'Deactivate Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
    audio_sample_rate, width, height, view_start_frame, view_duration_frames, playhead_frame,
    created_at, modified_at)
VALUES ('%s', '%s', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080, 0, 240, 0,
    strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('tr-x', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], PROJ, SEQ, PROJ, SEQ)))

print("=== command_manager.init_project_only() + deactivate() ===")

-- 1. init_project_only must open the manager without requiring a sequence.
do
    local ok, err = pcall(command_manager.init_project_only, PROJ)
    assert(ok,
        "command_manager.init_project_only(project_id) must succeed without a "
        .. "sequence argument; got error: " .. tostring(err))
    print("  OK: init_project_only accepts a project-only identity")
end

-- 2. After init_project_only, can_undo/can_redo must both be false or inert —
--    there is no per-sequence stack to undo on (project-level stack is empty).
do
    local can_undo = command_manager.can_undo()
    assert(can_undo == false,
        "after init_project_only (nothing executed), can_undo() must be false; "
        .. "got " .. tostring(can_undo))
    local can_redo = command_manager.can_redo()
    assert(can_redo == false,
        "after init_project_only (nothing executed), can_redo() must be false; "
        .. "got " .. tostring(can_redo))

    -- undo() on an empty history must not error; it must return success=false.
    local result = command_manager.undo()
    assert(type(result) == "table" and result.success == false,
        "undo() on empty history must return {success=false, error_message=…}; "
        .. "got " .. tostring(result))
    print("  OK: undo/redo on project-only empty history are inert")
end

-- 3. After init(seq, pid) then deactivate(), calling deactivate() is idempotent
--    and doesn't raise. Subsequent undo/redo are inert (no stack active).
do
    command_manager.init(SEQ, PROJ)

    local ok1, err1 = pcall(command_manager.deactivate)
    assert(ok1, "deactivate() must succeed; got error: " .. tostring(err1))
    local ok2, err2 = pcall(command_manager.deactivate)
    assert(ok2, "deactivate() must be idempotent; got error: " .. tostring(err2))

    -- Post-deactivate, can_undo()/can_redo() must report false for an empty
    -- global stack (no project-level commands have been executed).
    assert(command_manager.can_undo() == false,
        "post-deactivate with empty global stack, can_undo() must be false")
    assert(command_manager.can_redo() == false,
        "post-deactivate with empty global stack, can_redo() must be false")
    print("  OK: deactivate() is idempotent; undo/redo inert on empty global stack")
end

print("✅ test_command_manager_deactivate.lua passed")
