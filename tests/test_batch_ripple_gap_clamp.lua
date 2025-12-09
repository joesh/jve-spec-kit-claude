#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_batch_ripple_gap_clamp.db"
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
            1000, 1, 48000, 1920, 1080, 0, 6000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES 
        ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('track_v2', 'default_sequence', 'Video 2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 20000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_a', 'default_project', 'timeline', 'A', 'track_v1', 'media1', 'default_sequence',
         0, 2000, 0, 2000, 1000, 1, 1, 0, %d, %d),
        ('clip_b', 'default_project', 'timeline', 'B', 'track_v1', 'media1', 'default_sequence',
         14000, 1000, 0, 1000, 1000, 1, 1, 0, %d, %d),
        ('clip_left_v2', 'default_project', 'timeline', 'Left V2', 'track_v2', 'media1', 'default_sequence',
         2000, 3000, 0, 3000, 1000, 1, 1, 0, %d, %d),
        ('clip_right', 'default_project', 'timeline', 'Right', 'track_v2', 'media1', 'default_sequence',
         13000, 1000, 0, 1000, 1000, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now, now, now)
assert(db:exec(seed))

command_manager.init(db, "default_sequence", "default_project")

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_left_v2", edge_type = "gap_after", track_id = "track_v2"}
})
cmd:set_parameter("delta_frames", 20000) -- drag upstream [ RIGHT to close until clamp

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit should clamp instead of overlapping")

local stmt = assert(db:prepare("SELECT timeline_start_frame FROM clips WHERE id = 'clip_right'"))
assert(stmt:exec() and stmt:next(), "clip_right missing after ripple")
local right_start = tonumber(stmt:value(0))
stmt:finalize()
assert(right_start == 5000, string.format("clip_right should clamp to its left neighbor (expected 5000, got %s)", tostring(right_start)))

local stmt2 = assert(db:prepare("SELECT timeline_start_frame FROM clips WHERE id = 'clip_b'"))
assert(stmt2:exec() and stmt2:next(), "clip_b missing after ripple")
local track_v1_start = tonumber(stmt2:value(0))
stmt2:finalize()
assert(track_v1_start == 6000, string.format("clip_b should shift with ripple (expected 6000, got %s)", tostring(track_v1_start)))

os.remove(TEST_DB)
print("✅ BatchRippleEdit clamps gap-before ripple to avoid overlaps")
