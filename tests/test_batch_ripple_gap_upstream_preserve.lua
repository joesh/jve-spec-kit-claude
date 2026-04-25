#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local import_schema = require("import_schema")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_batch_ripple_gap_upstream_preserve.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(import_schema))

local now = os.time()
local sql = string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Default', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('seq', 'proj', 'Seq', 'nested',
            24, 1, 48000, 1920, 1080, 0, 10000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
        ('v1', 'seq', 'V1', 'VIDEO', 1, 1),
        ('v2', 'seq', 'V2', 'VIDEO', 2, 1);

    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj', 'placeholder', '_placeholder', 480, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 480, 0, 480, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('clip_v1_upstream', 'proj', 'V1 Upstream', 'v1', '_v13_placeholder_master', 'seq', 100, 480, 0, 480, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_v2_left', 'proj', 'V2 Left', 'v2', '_v13_placeholder_master', 'seq', 580, 240, 0, 240, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_v2_right', 'proj', 'V2 Right', 'v2', '_v13_placeholder_master', 'seq', 1060, 240, 0, 240, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now)
assert(db:exec(sql))

command_manager.init("seq", "proj")

local cmd = Command.create("BatchRippleEdit", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("edge_infos", {
    {clip_id = "gap_v2_820", edge_type = "out", track_id = "v2", trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", -120)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

local v1_clip = Clip.load("clip_v1_upstream", db)
local v2_right = Clip.load("clip_v2_right", db)

assert(v1_clip.timeline_start == 100,
    string.format("Cross-track upstream clip moved from 100 to %d", v1_clip.timeline_start))
assert(v2_right.timeline_start == 940,
    string.format("V2 downstream clip should shift upstream to 940 when closing the gap; got %d", v2_right.timeline_start))

os.remove(TEST_DB)
print("✅ BatchRippleEdit keeps cross-track upstream clips anchored when rippling gaps")
