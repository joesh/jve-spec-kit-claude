#!/usr/bin/env luajit
-- Debug test for masterclip creation
package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")
local database = require("core.database")

local db_path = "/tmp/jve/debug_masterclip.db"
os.remove(db_path)
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

-- Insert project
local now = os.time()
db:exec(string.format("INSERT INTO projects (id, name, created_at, modified_at) VALUES (%q, %q, %d, %d);", "project", "Test", now, now))

-- Insert media
local Media = require("models.media")
local media = Media.create({
    id = "media_test",
    project_id = "project",
    file_path = "/tmp/test.mov",
    name = "Test Media",
    duration_frames = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)
print("Media saved with id: media_test")

-- Create masterclip
local mc_id = test_env.create_test_masterclip_sequence("project", "Test Master", 30, 1, 100, "media_test")
print("Masterclip sequence id:", mc_id)

-- Now check the stream clip
local Sequence = require("models.sequence")
local seq = Sequence.load(mc_id)
print("Sequence loaded:", seq and "yes" or "no")
print("Is masterclip:", seq and seq:is_masterclip() and "yes" or "no")
local video_stream = seq and seq:video_stream()
print("Video stream:", video_stream and "found" or "nil")
print("Video stream media_id:", video_stream and video_stream.media_id or "nil")

-- Query clips directly
local stmt = db:prepare("SELECT id, media_id, track_id FROM clips")
stmt:exec()
print("\nAll clips in DB:")
while stmt:next() do
    print(string.format("  id=%s media_id=%s track_id=%s",
        tostring(stmt:value(0)), tostring(stmt:value(1)), tostring(stmt:value(2))))
end
stmt:finalize()

print("\n✅ Debug test complete")
