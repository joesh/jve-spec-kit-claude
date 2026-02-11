#!/usr/bin/env luajit
-- Regression: Insert command with media_id but no duration info returns cryptic error.
-- User sees "Insert: invalid duration_frames=nil" instead of helpful message about
-- needing to specify duration or use a master clip with duration info.
--
-- Scenario: User clicks Timeline > Insert with media selected but without marks set.
-- The Insert command gets media_id from project browser but cannot infer duration
-- without: duration param, source_out param, or master_clip_id with duration.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local db_path = "/tmp/jve/test_insert_menu_requires_selection.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

-- Seed project/sequence/track
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('project', 'InsertMenuTest', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

-- Create media with valid duration
db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, created_at, modified_at)
    VALUES ('media_valid', 'project', 'Valid Media', '/fake/path.mov', 300, 30, 1, 1920, 1080, %d, %d);
]], now, now))

command_manager.init("sequence", "project")

-- Create masterclip sequence for the media (required for Insert)
local master_clip_id = test_env.create_test_masterclip_sequence(
    'project', 'Valid Media Master', 30, 1, 300, 'media_valid')

-- Register Insert command
local insert_cmd = require("core.commands.insert")
local ret = insert_cmd.register({}, {}, db, command_manager.set_last_error)
command_manager.register_executor("Insert", ret.executor, ret.undoer)

print("\n=== Insert with media_id but no duration/source_out ===")

-- Simulate menu dispatch: master_clip_id is known but no duration info provided.
-- This happens when user clicks Insert without setting in/out marks.
-- Insert should infer duration from the masterclip's stream clips.
local cmd = Command.create("Insert", "project")
cmd:set_parameter("project_id", "project")
cmd:set_parameter("sequence_id", "sequence")
cmd:set_parameter("track_id", "track_v1")
cmd:set_parameter("master_clip_id", master_clip_id)
-- NOTE: no duration, source_in, source_out provided - should infer from masterclip

command_manager.begin_command_event("script")
local result = command_manager.execute(cmd)
command_manager.end_command_event()

-- The command should succeed by using media's duration_frames
if not result.success then
    local err = result.error_message or ""
    -- Check for the regression: cryptic "duration_frames=nil" error
    if err:match("duration_frames=nil") then
        print("REGRESSION: Insert returns cryptic 'duration_frames=nil' error")
        print("Expected: Insert should use media's duration_frames automatically")
        os.exit(1)
    end
    print("FAIL: Insert failed with error: " .. err)
    os.exit(1)
end

print("Test passed: Insert uses masterclip stream duration when no explicit duration provided")
