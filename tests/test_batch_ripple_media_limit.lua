#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_batch_ripple_media_limit.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
local seed = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline',
            24, 1, 48000, 1920, 1080, 0, 1000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_media_lock', 'default_project', 'timeline', 'LockClip', 'track_v1', NULL, 'default_sequence',
         240, 480, 120, 600, 24, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now)
assert(db:exec(seed))

command_manager.init("default_sequence", "default_project")

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_media_lock", edge_type = "in", track_id = "track_v1", trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", -360) -- aim to stretch 15s left

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit should succeed when clamped")

local clip = Clip.load("clip_media_lock", db)
assert(clip.timeline_start == 240, string.format("Ripple trim should keep clip anchored; expected 240, got %d", clip.timeline_start))
assert(clip.source_in == 0, string.format("source_in should clamp at 0; got %d", clip.source_in))
assert(clip.duration == 600, string.format("duration should extend only by available handle; expected 600, got %d", clip.duration))
assert(clip.source_out == 600, string.format("source_out should equal source_in + duration; expected 600, got %d", clip.source_out))

os.remove(TEST_DB)
print("✅ Batch ripple clamps upstream extension to source media length")
