#!/usr/bin/env luajit
-- Regression: Insert must not crash at snapshot boundary.
-- The command manager takes a snapshot every 50 commands; this test verifies
-- that Insert commands work correctly when hitting a snapshot boundary.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")

local database = require("core.database")
local Command = require("command")
local Clip = require("models.clip")
local Media = require("models.media")
local command_history = require("core.command_history")
local command_manager = require("core.command_manager")
local snapshot_manager = require("core.snapshot_manager")

local db_path = "/tmp/jve/test_insert_snapshot_boundary.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Seed project/sequence/track (24fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('project', 'SnapshotBoundary', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Seq', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init("sequence", "project")

-- Register Insert command
local insert_cmd = require("core.commands.insert")
local ret = insert_cmd.register({}, {}, db, command_manager.set_last_error)
command_manager.register_executor("Insert", ret.executor, ret.undoer)
command_manager.register_executor("UndoInsert", ret.executor, ret.undoer)

-- Media backing for the inserted clip
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/media_1.mov",
    name = "Media 1",
    duration_frames = 240,
    fps_numerator = 24,
    fps_denominator = 1
})
assert(media:save(db), "Failed to save media_1")

-- Create masterclip sequence for this media (required for Insert)
local master_clip_id = test_env.create_test_masterclip_sequence(
    "project", "Media 1 Master", 24, 1, 240, "media_1")

-- Advance sequence numbering to just before the snapshot interval so the next command triggers it.
local interval = snapshot_manager.SNAPSHOT_INTERVAL or 50
for _ = 1, interval - 1 do
    command_history.increment_sequence_number()
end

local cmd = Command.create("Insert", "project")
cmd:set_parameter("master_clip_id", master_clip_id)
cmd:set_parameter("track_id", "track_v1")
cmd:set_parameter("sequence_id", "sequence")
cmd:set_parameter("insert_time", 0)
cmd:set_parameter("duration", 24)
cmd:set_parameter("source_in", 0)
cmd:set_parameter("source_out", 24)
cmd:set_parameter("project_id", "project")
cmd:set_parameter("clip_name", "BoundaryInsert")

print("\n=== Insert at snapshot boundary (expect success) ===")
local ok, result = pcall(function()
    return command_manager.execute(cmd)
end)

if not ok then
    print("❌ Insert raised error at snapshot boundary: " .. tostring(result))
    os.exit(1)
end
if not result or not result.success then
    print("❌ Insert failed: " .. tostring(result and result.error_message))
    os.exit(1)
end

-- Snapshot should have been recorded for the active sequence.
local stmt = db:prepare("SELECT COUNT(*) FROM snapshots WHERE sequence_id = 'sequence'")
assert(stmt, "Failed to prepare snapshot count query")
assert(stmt:exec(), "Snapshot count query failed")
stmt:next()
local snap_count = stmt:value(0)
stmt:finalize()

if snap_count < 1 then
    print("❌ Snapshot not created for sequence at boundary")
    os.exit(1)
end

-- Verify the clip actually landed in the timeline.
local clip_stmt = db:prepare([[
    SELECT COUNT(*) FROM clips
    WHERE track_id = 'track_v1' AND timeline_start_frame = 0 AND duration_frames = 24
]])
assert(clip_stmt:exec(), "Clip lookup failed")
clip_stmt:next()
local clip_count = clip_stmt:value(0)
clip_stmt:finalize()

if clip_count ~= 1 then
    print("❌ Inserted clip not found in timeline")
    os.exit(1)
end

print("✅ Insert succeeded and snapshot captured at boundary")
os.exit(0)
