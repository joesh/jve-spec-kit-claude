#!/usr/bin/env luajit
-- Regression Test: Complex Overwrite (Straddling Two Clips)
-- Verifies Overwrite command correctly trims the tail of the first clip
-- and the head of the second clip when overwriting across their boundary.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')

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
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('project', 'Test', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[ 
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 'nested', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[ 
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

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

-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_1")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media_1", "project")

-- Create masterclip sequence for this media (required for Overwrite)
local nested_sequence_id = test_env.create_test_masterclip_sequence(
    "project", "Media 1 Master", 24, 1, 1000, "media_1")

-- Create Clip A (0-100 frames)
local clip_a = Clip.create({
        name = "Clip A",
        project_id = "project",
        track_id = "track_v1",
        owner_sequence_id = "sequence",
        nested_sequence_id = MC_TEST,
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
assert(clip_a:save(db), "Failed to save Clip A")

-- Create Clip B (100-200 frames)
local clip_b = Clip.create({
        name = "Clip B",
        project_id = "project",
        track_id = "track_v1",
        owner_sequence_id = "sequence",
        nested_sequence_id = MC_TEST,
        timeline_start_frame = 100,
        duration_frames = 100,
        source_in_frame = 100,
        source_out_frame = 200,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
assert(clip_b:save(db), "Failed to save Clip B")

print("Created Clip A (0-100) and Clip B (100-200)")

-- Execute Overwrite (50-150 frames)
-- Should trim A to 0-50.
-- Should trim B to 150-200 (start moves to 150, duration 50).
-- New Clip C inserted at 50-150.

-- Set marks on masterclip sequence — Overwrite reads timing from these
local Sequence = require("models.sequence")
local mc_seq = Sequence.load(nested_sequence_id)
assert(mc_seq, "Failed to load masterclip sequence")
mc_seq:set_in(0)
mc_seq:set_out(100)
mc_seq:save()

local cmd = Command.create("Overwrite", "project")
cmd:set_parameter("nested_sequence_id", nested_sequence_id)
cmd:set_parameter("target_video_track_id", "track_v1")
cmd:set_parameter("sequence_id", "sequence")
cmd:set_parameter("overwrite_time", 50)
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
if a_after.duration == 50 then
    print("✅ Clip A duration is 50 (Correct)")
else
    print(string.format("❌ Clip A duration mismatch: expected 50, got %d", a_after.duration))
    os.exit(1)
end

-- Clip B
if b_after.timeline_start == 150 then
    print("✅ Clip B start is 150 (Correct)")
else
    print(string.format("❌ Clip B start mismatch: expected 150, got %d", b_after.timeline_start))
    os.exit(1)
end
if b_after.duration == 50 then
    print("✅ Clip B duration is 50 (Correct)")
else
    print(string.format("❌ Clip B duration mismatch: expected 50, got %d", b_after.duration))
    os.exit(1)
end

-- Clip C
if c_after.timeline_start == 50 then
    print("✅ Clip C start is 50 (Correct)")
else
    print(string.format("❌ Clip C start mismatch: expected 50, got %d", c_after.timeline_start))
    os.exit(1)
end
if c_after.duration == 100 then
    print("✅ Clip C duration is 100 (Correct)")
else
    print(string.format("❌ Clip C duration mismatch: expected 100, got %d", c_after.duration))
    os.exit(1)
end

print("\nAll checks passed.")
os.exit(0)
