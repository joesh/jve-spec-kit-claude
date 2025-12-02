#!/usr/bin/env luajit
-- Regression Test: Complex Overwrite (Straddling Two Clips)
-- Verifies Overwrite command correctly trims the tail of the first clip
-- and the head of the second clip when overwriting across their boundary.

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

print("=== Testing Complex Overwrite (Straddle) ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_overwrite_complex.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence (24fps)
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
    duration_frames = 1000,
    fps_numerator = 24,
    fps_denominator = 1
})
media:save(db)

-- Create Clip A (0-100 frames)
local clip_a = Clip.create("Clip A", "media_1", {
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = Rational.new(0, 24, 1),
    duration = Rational.new(100, 24, 1),
    source_in = Rational.new(0, 24, 1),
    source_out = Rational.new(100, 24, 1),
    enabled = true,
    rate_num = 24,
    rate_den = 1
})
assert(clip_a:save(db), "Failed to save Clip A")

-- Create Clip B (100-200 frames)
local clip_b = Clip.create("Clip B", "media_1", {
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = Rational.new(100, 24, 1),
    duration = Rational.new(100, 24, 1),
    source_in = Rational.new(100, 24, 1),
    source_out = Rational.new(200, 24, 1),
    enabled = true,
    rate_num = 24,
    rate_den = 1
})
assert(clip_b:save(db), "Failed to save Clip B")

print("Created Clip A (0-100) and Clip B (100-200)")

-- Execute Overwrite (50-150 frames)
-- Should trim A to 0-50.
-- Should trim B to 150-200 (start moves to 150, duration 50).
-- New Clip C inserted at 50-150.

local cmd = Command.create("Overwrite", "project")
cmd:set_parameter("media_id", "media_1")
cmd:set_parameter("track_id", "track_v1")
cmd:set_parameter("sequence_id", "sequence")
cmd:set_parameter("overwrite_time", Rational.new(50, 24, 1))
cmd:set_parameter("duration", Rational.new(100, 24, 1))
cmd:set_parameter("source_in", Rational.new(0, 24, 1))
cmd:set_parameter("source_out", Rational.new(100, 24, 1))
cmd:set_parameter("clip_name", "Clip C")

print("Executing Overwrite (50-150)...")
local result = command_manager.execute(cmd)

if not result.success then
    print("❌ Overwrite failed: " .. tostring(result.error_message))
    os.exit(1)
end

print("✅ Overwrite succeeded")

-- Verify DB State
local function get_clip(id)
    return Clip.load(id, db)
end

local a_after = get_clip(clip_a.id)
local b_after = get_clip(clip_b.id)
local c_id = cmd:get_parameter("clip_id")
local c_after = get_clip(c_id)

print("\nVerifying state:")

-- Clip A
if a_after.duration.frames == 50 then
    print("✅ Clip A duration is 50 (Correct)")
else
    print(string.format("❌ Clip A duration mismatch: expected 50, got %d", a_after.duration.frames))
    os.exit(1)
end

-- Clip B
if b_after.timeline_start.frames == 150 then
    print("✅ Clip B start is 150 (Correct)")
else
    print(string.format("❌ Clip B start mismatch: expected 150, got %d", b_after.timeline_start.frames))
    os.exit(1)
end
if b_after.duration.frames == 50 then
    print("✅ Clip B duration is 50 (Correct)")
else
    print(string.format("❌ Clip B duration mismatch: expected 50, got %d", b_after.duration.frames))
    os.exit(1)
end

-- Clip C
if c_after.timeline_start.frames == 50 then
    print("✅ Clip C start is 50 (Correct)")
else
    print(string.format("❌ Clip C start mismatch: expected 50, got %d", c_after.timeline_start.frames))
    os.exit(1)
end
if c_after.duration.frames == 100 then
    print("✅ Clip C duration is 100 (Correct)")
else
    print(string.format("❌ Clip C duration mismatch: expected 100, got %d", c_after.duration.frames))
    os.exit(1)
end

print("\nAll checks passed.")
os.exit(0)
