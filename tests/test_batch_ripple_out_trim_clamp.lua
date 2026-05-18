#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_batch_ripple_out_trim_clamp.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
local seed = string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('default_project', 'Default', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'sequence',
            1000, 1, 48000, 1920, 1080, 0, 6000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES 
        ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
        ('track_v2', 'default_sequence', 'Video 2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 20000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    -- V13 master sequence + track + media_ref for media1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media1', 'default_project', 'media1_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media1', 'master_media1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media1' WHERE id = 'master_media1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media1', 'default_project', 'master_media1', 'master_v_media1', 'media1', 0, 20000, 0, 20000, 48000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_left', 'default_project', 'Left', 'track_v1', 'master_media1', 'default_sequence', 0, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_right', 'default_project', 'Right', 'track_v1', 'master_media1', 'default_sequence', 4000, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_other_track', 'default_project', 'Other', 'track_v2', 'master_media1', 'default_sequence', 5000, 1500, 0, 1500, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now, now, now, now, now)
assert(db:exec(seed))

command_manager.init("default_sequence", "default_project")

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_left", edge_type = "out", track_id = "track_v1"}
})
cmd:set_parameter("delta_frames", 6000) -- Attempt to extend far beyond neighbor

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed to extend clip")

local left_clip = Clip.load("clip_left", db)
assert(left_clip ~= nil, "clip_left missing after ripple")
assert(left_clip.duration == 8000, string.format("clip_left should extend by requested delta; expected duration 8000, got %s", tostring(left_clip.duration)))

local right_clip = Clip.load("clip_right", db)
assert(right_clip ~= nil, "clip_right missing after ripple")
assert(right_clip.sequence_start == 10000, string.format("Downstream clip should shift by ripple delta; expected 10000, got %s", tostring(right_clip.sequence_start)))

local other_clip = Clip.load("clip_other_track", db)
assert(other_clip ~= nil, "clip_other_track missing after ripple")
assert(other_clip.sequence_start == 11000, string.format("Other track should shift by ripple delta; expected 11000, got %s", tostring(other_clip.sequence_start)))

os.remove(TEST_DB)
print("✅ BatchRippleEdit extends out-point ripple and shifts unrelated tracks correctly")
