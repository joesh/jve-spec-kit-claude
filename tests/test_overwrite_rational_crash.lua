#!/usr/bin/env luajit
-- Regression Test: Overwrite Command Rational Crash
-- Reproduces "compare number with table" in clip_mutator during Overwrite

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Testing Overwrite Rational Crash ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_overwrite_crash.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence
local now = os.time()
db:exec(string.format([[ 
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test', %d, %d);
]], now, now))
db:exec(string.format([[ 
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[ 
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init(db, 'sequence', 'project')

-- Create Media
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/media_1.mov",
    name = "Media 1",
    duration_frames = 240, -- 10s @ 24fps
    fps_numerator = 24,
    fps_denominator = 1
})
media:save(db)

-- Create Existing Clip (0-100 frames)
local clip_existing = Clip.create("Existing", "media_1", {
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = Rational.new(0, 24, 1),
    duration = Rational.new(100, 24, 1),
    source_in = Rational.new(0, 24, 1),
    source_out = Rational.new(100, 24, 1),
    enabled = true
})
clip_existing:save(db)

print("Created existing clip at 0-100 frames")

-- Execute Overwrite (Overlap 50-150)
-- This triggers clip_mutator to resolve occlusion (trim existing clip)
local cmd = Command.create("Overwrite", "project")
cmd:set_parameter("media_id", "media_1")
cmd:set_parameter("track_id", "track_v1")
cmd:set_parameter("sequence_id", "sequence")
-- Rationals
cmd:set_parameter("overwrite_time", Rational.new(50, 24, 1))
cmd:set_parameter("duration", Rational.new(100, 24, 1))
cmd:set_parameter("source_in", Rational.new(0, 24, 1))
cmd:set_parameter("source_out", Rational.new(100, 24, 1))

print("Executing Overwrite...")
local result = command_manager.execute(cmd)

if result.success then
    print("✅ Overwrite succeeded")
else
    print("❌ Overwrite failed: " .. tostring(result.error_message))
    os.exit(1) -- Fail
end

print("Test Passed")
os.exit(0)
