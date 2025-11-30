#!/usr/bin/env luajit

-- Regression: importing a sequence and undoing back to the root should remove
-- the imported timeline and its media instead of leaving an empty shell behind.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")

local function stub_timeline_state()
    local current_sequence_id = "default_sequence"

    timeline_state.capture_viewport = function()
        return {start_value = 0, duration_value = 300, timebase_type = "video_frames", timebase_rate = 30.0}
    end
    timeline_state.push_viewport_guard = function() end
    timeline_state.pop_viewport_guard = function() end
    timeline_state.restore_viewport = function(_) end
    timeline_state.set_selection = function(_) end
    timeline_state.set_edge_selection = function(_) end
    timeline_state.set_gap_selection = function(_) end
    timeline_state.get_selected_clips = function() return {} end
    timeline_state.get_selected_edges = function() return {} end
    timeline_state.set_playhead_position = function(_) end
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_project_id = function() return "default_project" end
    timeline_state.get_sequence_id = function() return current_sequence_id end
    timeline_state.reload_clips = function(sequence_id)
        if sequence_id and sequence_id ~= "" then
            current_sequence_id = sequence_id
        end
    end
end

local function exec(db, sql)
    local ok, err = db:exec(sql)
    assert(ok, err)
end

local function scalar(db, sql, value)
    local stmt = db:prepare(sql)
    assert(stmt, "Failed to prepare statement: " .. sql)
    if value ~= nil then
        stmt:bind_value(1, value)
    end
    local result = 0
    if stmt:exec() and stmt:next() then
        result = stmt:value(0) or 0
    end
    stmt:finalize()
    return result
end

local tmp_db = "/tmp/jve/test_import_undo_removes_sequence.db"
os.remove(tmp_db)
assert(database.init(tmp_db))
local db = database.get_connection()

local SCHEMA_SQL = require("import_schema")
exec(db, SCHEMA_SQL)

local now = os.time()
exec(db, string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Sequence 1', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
]], now, now))

stub_timeline_state()

command_manager.init(db, "default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

local fixture_path = "../tests/fixtures/resolve/sample_timeline_fcp7xml.xml"

local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("project_id", "default_project")
import_cmd:set_parameter("xml_path", fixture_path)

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, "ImportFCP7XML command should succeed")

local baseline_sequences = scalar(db, "SELECT COUNT(*) FROM sequences WHERE kind = 'timeline'")
assert(baseline_sequences == 2, "Import should create an additional timeline sequence")

local imported_exists = scalar(db, "SELECT COUNT(*) FROM sequences WHERE name = 'Timeline 1 (Resolve)'")
assert(imported_exists == 1, "Imported sequence should be present after import")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undoing the import should succeed")

local sequences_after = scalar(db, "SELECT COUNT(*) FROM sequences WHERE kind = 'timeline'")
assert(sequences_after == 1, "Undo should remove the imported timeline sequence")

local imported_after = scalar(db, "SELECT COUNT(*) FROM sequences WHERE name = 'Timeline 1 (Resolve)'")
assert(imported_after == 0, "Imported sequence should be gone after undo")

local media_after = scalar(db, "SELECT COUNT(*) FROM media")
assert(media_after == 0, "Imported media should be removed after undo")

os.remove(tmp_db)
print("✅ Import undo removes generated timeline and media")
