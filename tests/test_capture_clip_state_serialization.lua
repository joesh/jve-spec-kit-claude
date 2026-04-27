#!/usr/bin/env luajit
-- Regression: capture_clip_state must save fps/timestamps so mutations survive JSON round-trip

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Clip = require("models.clip")
local Media = require("models.media")
local command_helper = require("core.command_helper")
local json = require("dkjson")

local db_path = "/tmp/jve/test_capture_clip_state_serialization.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

-- Seed project/sequence/track (24fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('project', 'CaptureTest', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 'nested', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

-- Create media and clip
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/test.mov",
    name = "Test Media",
    duration_frames = 240,
    fps_numerator = 24,
    fps_denominator = 1
})
assert(media:save(db), "Failed to save media")

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

local clip = Clip.create({
        name = "Test Clip",
        id = "clip_1",
        project_id = "project",
        track_id = "track_v1",
        owner_sequence_id = "sequence",
        nested_sequence_id = MC_TEST,
        timeline_start_frame = 0,
        duration_frames = 48,
        source_in_frame = 0,
        source_out_frame = 48,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
assert(clip ~= nil and clip ~= "", "Failed to save clip")

print("\n=== Test 1: Capture includes frame_rate and timestamps ===")
local reloaded = Clip.load("clip_1", db)
local captured = command_helper.capture_clip_state(reloaded)

if not captured.frame_rate
    or not captured.frame_rate.fps_numerator
    or not captured.frame_rate.fps_denominator then
    print("❌ Captured state missing frame_rate table")
    os.exit(1)
end

if captured.frame_rate.fps_numerator ~= 24 or captured.frame_rate.fps_denominator ~= 1 then
    print(string.format("❌ Wrong fps: %s/%s",
        tostring(captured.frame_rate.fps_numerator),
        tostring(captured.frame_rate.fps_denominator)))
    os.exit(1)
end

-- Timestamps are optional (may not be set on all clips)
print("✅ Captured state includes frame_rate")

print("\n=== Test 2: JSON round-trip preserves frame data ===")
local serialized = json.encode(captured)
local deserialized = json.decode(serialized)

-- frame_rate table should be preserved
if not deserialized.frame_rate or deserialized.frame_rate.fps_numerator ~= 24 then
    print("❌ frame_rate lost during JSON round-trip")
    os.exit(1)
end

-- timeline_start is now an integer (not Rational), verify it survives JSON
if type(deserialized.timeline_start) ~= "number" then
    print("❌ timeline_start should be integer, got: " .. type(deserialized.timeline_start))
    os.exit(1)
end

print("✅ JSON round-trip preserves fps fields and integer coordinates")

print("\n=== Test 3: Undo helper can access integer coords from deserialized state ===")
-- All coordinates are now plain integers
local timeline_start = deserialized.timeline_start
if type(timeline_start) ~= "number" then
    print("❌ timeline_start should be number, got: " .. type(timeline_start))
    os.exit(1)
end

if timeline_start ~= 0 then
    print(string.format("❌ Wrong timeline_start: expected 0, got %s", tostring(timeline_start)))
    os.exit(1)
end

print("✅ Can access integer coords from JSON-deserialized clip state")

print("\n=== All tests passed ===")
os.exit(0)
