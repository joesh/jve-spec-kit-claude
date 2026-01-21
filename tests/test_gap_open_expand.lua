#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_gap_open_expand.db"
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
            24, 1, 48000, 1920, 1080, 0, 4000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 1000, 24, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'media1', 'default_sequence',
         0, 200, 0, 200, 24, 1, 1, 0, %d, %d),
        ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'media1', 'default_sequence',
         400, 200, 0, 200, 24, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)
assert(db:exec(seed))

command_manager.init("default_sequence", "default_project")

local gap_target = Clip.load("clip_right", db)
assert(gap_target.timeline_start.frames == 400, "initial clip start mismatch")

local cmd = Command.create("RippleEdit", "default_project")
cmd:set_parameter("edge_info", {
    clip_id = gap_target.id,
    edge_type = "gap_before",
    track_id = gap_target.track_id
})
cmd:set_parameter("delta_frames", -48) -- drag ] right by 2 seconds (48 frames @24fps)
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "RippleEdit gap open failed")

local after = Clip.load(gap_target.id, db)
assert(after.timeline_start.frames == 352,
    string.format("Gap open should extend to frame 352, got %d", after.timeline_start.frames))

os.remove(TEST_DB)
print("✅ RippleEdit gap open (dragging ] left) increases available gap distance")
