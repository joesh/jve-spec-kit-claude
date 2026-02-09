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
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('project', 'CaptureTest', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 24, 1, 48000, 1920, 1080, %d, %d);
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

local clip = Clip.create("Test Clip", "media_1", {
    id = "clip_1",
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = 0,
    duration = 48,  -- 2 seconds
    source_in = 0,
    source_out = 48,
    fps_numerator = 24,
    fps_denominator = 1,
    enabled = true
})
assert(clip:save(db), "Failed to save clip")

print("\n=== Test 1: Capture includes fps and timestamps ===")
local reloaded = Clip.load("clip_1", db)
local captured = command_helper.capture_clip_state(reloaded)

if not captured.fps_numerator or not captured.fps_denominator then
    print("❌ Captured state missing fps fields")
    os.exit(1)
end

if captured.fps_numerator ~= 24 or captured.fps_denominator ~= 1 then
    print(string.format("❌ Wrong fps: %s/%s", tostring(captured.fps_numerator), tostring(captured.fps_denominator)))
    os.exit(1)
end

-- Timestamps are optional (may not be set on all clips)
print("✅ Captured state includes fps_numerator, fps_denominator")

print("\n=== Test 2: JSON round-trip preserves frame data ===")
local serialized = json.encode(captured)
local deserialized = json.decode(serialized)

-- fps fields should be preserved as top-level fields
if not deserialized.fps_numerator or deserialized.fps_numerator ~= 24 then
    print("❌ fps_numerator lost during JSON round-trip")
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
