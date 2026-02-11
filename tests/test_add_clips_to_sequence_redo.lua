#!/usr/bin/env luajit

-- Regression test: AddClipsToSequence redo must hydrate Rational fields
-- Bug: groups[].duration deserialized as plain table, not Rational

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Media = require('models.media')
local command_manager = require('core.command_manager')

print("=== AddClipsToSequence Redo Hydration Test ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_add_clips_redo.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence (24fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Create media
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/video1.mov",
    name = "Video 1",
    duration_frames = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
})
media:save(db)

-- Create masterclip sequences (IS-a refactor: masterclip IS a sequence)
local test_env = require("test_env")
local master_1 = test_env.create_test_masterclip_sequence("project", "Master 1", 24, 1, 100, "media_1")
local master_2 = test_env.create_test_masterclip_sequence("project", "Master 2", 24, 1, 100, "media_1")

-- Helper: count timeline clips
local function count_timeline_clips()
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = 'track_v1'")
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- =============================================================================
-- TEST: Execute → Undo → Redo cycle for AddClipsToSequence
-- =============================================================================
print("Test: AddClipsToSequence execute → undo → redo cycle")

-- Build groups with Rational durations
local groups = {
    {
        master_clip_id = master_1,  -- variable, not string
        duration = 50,
        clips = {
            {
                role = "video",
                media_id = "media_1",
                master_clip_id = master_1,  -- variable, not string
                project_id = "project",
                name = "Clip 1",
                source_in = 0,
                source_out = 50,
                duration = 50,
                fps_numerator = 24,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        }
    },
    {
        master_clip_id = master_2,  -- variable, not string
        duration = 75,
        clips = {
            {
                role = "video",
                media_id = "media_1",
                master_clip_id = master_2,  -- variable, not string
                project_id = "project",
                name = "Clip 2",
                source_in = 0,
                source_out = 75,
                duration = 75,
                fps_numerator = 24,
                fps_denominator = 1,
                target_track_id = "track_v1",
            }
        }
    },
}

-- Execute
print("  Executing AddClipsToSequence...")
command_manager.begin_command_event("test")
local result = command_manager.execute("AddClipsToSequence", {
    groups = groups,
    position = 0,
    sequence_id = "sequence",
    project_id = "project",
    edit_type = "overwrite",
    arrangement = "serial",
})
command_manager.end_command_event()

assert(result and result.success, "Execute should succeed: " .. tostring(result and result.error_message))
local count_after_exec = count_timeline_clips()
print(string.format("  Clips after execute: %d", count_after_exec))
assert(count_after_exec == 2, "Should have 2 clips after execute")

-- Undo
print("  Undoing...")
local undo_result = command_manager.undo()
assert(undo_result, "Undo should succeed")
local count_after_undo = count_timeline_clips()
print(string.format("  Clips after undo: %d", count_after_undo))
assert(count_after_undo == 0, "Should have 0 clips after undo")

-- Redo (this is where the bug occurred - Rational fields not hydrated)
print("  Redoing (this is where hydration bug manifested)...")
local redo_result = command_manager.redo()
assert(redo_result, "Redo should succeed")
local count_after_redo = count_timeline_clips()
print(string.format("  Clips after redo: %d", count_after_redo))
assert(count_after_redo == 2, "Should have 2 clips after redo")

print("\n✅ test_add_clips_to_sequence_redo.lua passed")
