#!/usr/bin/env luajit

-- Regression test: DRP import provenance command.
-- Provenance is a history marker (seq=0, parent=-1), not an undoable command.
-- The undo system must never try to undo it.

require('test_env')

_G.qt_create_single_shot_timer = function() end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local Command = require('command')

print("=== DRP Provenance Command Tests ===")

local db_path = "/tmp/jve/test_drp_provenance.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")

database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Timeline', 'timeline', 25, 1, 48000, 1920, 1080,
        0, 500, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now, now, now))

-- Test 1: insert_provenance saves with sentinel values
print("Test 1: insert_provenance saves at sequence_number=0, parent=-1")
local ok, err = pcall(function()
    Command.insert_provenance("ImportResolveProject", "proj1", {
        drp_path = "/tmp/test.drp",
        source_name = "Test Project",
    })
end)
assert(ok, "insert_provenance should succeed: " .. tostring(err))

local stmt = db:prepare("SELECT command_type, sequence_number, parent_sequence_number FROM commands WHERE sequence_number = 0")
assert(stmt and stmt:exec() and stmt:next(), "provenance should be in commands table")
assert(stmt:value(0) == "ImportResolveProject", "command_type mismatch")
assert(stmt:value(1) == 0, "sequence_number should be 0")
assert(stmt:value(2) == -1, "parent should be -1 (sentinel)")
stmt:finalize()

-- Test 2: set_undo_cursor_for_project
print("Test 2: cursor set to 0")
local Sequence = require("models.sequence")
Sequence.set_undo_cursor_for_project("proj1", 0)
local check = db:prepare("SELECT current_sequence_number FROM sequences WHERE id = 'seq1'")
assert(check and check:exec() and check:next())
assert(check:value(0) == 0, "cursor should be 0, got " .. tostring(check:value(0)))
check:finalize()

-- Test 3: can_undo is false at cursor=0
print("Test 3: can_undo false at cursor=0")
local command_manager = require("core.command_manager")
command_manager.init("seq1", "proj1")
assert(not command_manager.can_undo(), "can_undo should be false at cursor=0")

-- Test 4: can_redo finds real commands but not provenance
print("Test 4: can_redo skips provenance at seq=0")
-- No real commands yet — only provenance at seq=0 with parent=-1
-- find_latest_child_command(0) should NOT find provenance (parent=-1, not 0)
assert(not command_manager.can_redo(), "can_redo should be false with only provenance")

print("✅ test_drp_provenance_command.lua passed")
