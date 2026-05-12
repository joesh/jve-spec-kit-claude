#!/usr/bin/env luajit
-- The history list shows a branch of possible actions, not just done
-- history. After jumping back to the top (global_cursor == 0), a
-- global command whose row is still in the DB (undone, redoable) must
-- still appear in the list — the user needs to see it to redo forward.

require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local history = require("core.command_history")

local TEST_DB = "/tmp/jve/test_history_shows_undone_globals.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('p', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height, playhead_frame, view_start_frame,
                           view_duration_frames, selected_clip_ids, selected_edge_infos,
                           selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 25, 1, 48000, 1920, 1080, 0, 0, 240,
            '[]', '[]', '[]', 0, %d, %d);
]], now, now, now, now))

command_manager.init("s", "p")

local function history_lists(type_name)
    local entries = command_manager:list_history_entries()
    for _, e in ipairs(entries) do
        if e.command_type == type_name then return true end
    end
    return false
end

-- Execute a global command (NewBin has no sequence_id → GLOBAL stack).
local cmd = Command.create("NewBin", "p")
cmd:set_parameter("bin_id", "b1")
cmd:set_parameter("name", "Bin1")
local r = command_manager.execute(cmd)
assert(r.success, "NewBin failed: " .. tostring(r.error_message))

assert(history_lists("NewBin"),
    "pre-condition: NewBin must appear in history list when done")

-- Undo back to provenance. global_cursor is now at the top.
local u = command_manager.undo()
assert(u.success, "undo failed: " .. tostring(u.error_message))
assert((history.get_global_cursor() or 0) == 0,
    "after undo, global_cursor must be 0/nil; got " ..
    tostring(history.get_global_cursor()))

-- The DB still holds the command (it's redoable, not deleted).
local q = db:prepare("SELECT COUNT(*) FROM commands WHERE command_type = 'NewBin'")
q:exec(); q:next()
local count = q:value(0)
q:finalize()
assert(count == 1,
    "NewBin row must remain in DB after undo; count=" .. count)

assert(history_lists("NewBin"),
    "undone global command must still be listed in history (it is redoable)")

print("✅ test_history_shows_undone_globals.lua passed")
