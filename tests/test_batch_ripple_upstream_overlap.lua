#!/usr/bin/env luajit

-- Regression for upstream handle ripple when the downstream clip must jump
-- past the original end-time of the edited clip. Previously the database UPDATE
-- order caused a VIDEO_OVERLAP constraint failure.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local import_schema = require("import_schema")
local Clip = require("models.clip")

local DB_PATH = "/tmp/jve/test_batch_ripple_upstream_overlap.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

local now = os.time()
local seed = string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Timeline', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('seq', 'proj', 'Sequence 1', 'nested',
            24, 1, 48000, 1920, 1080, 0, 20000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);

    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj', 'placeholder', '_placeholder', 4000, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 4000, 0, 4000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, nested_sequence_id, owner_sequence_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('clip_a', 'proj', 'A', 'v1', '_v13_placeholder_master', 'seq', 0, 4000, 0, 4000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_b', 'proj', 'B', 'v1', '_v13_placeholder_master', 'seq', 4500, 1500, 0, 1500, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now)
assert(db:exec(seed))

command_manager.init("seq", "proj")

local cmd = Command.create("BatchRippleEdit", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_a", edge_type = "in", track_id = "v1", trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", 1200) -- Drag upstream handle right 1200 frames

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit with upstream shrink should succeed")

local clip_a = Clip.load("clip_a", db)
local clip_b = Clip.load("clip_b", db)

assert(clip_a.timeline_start == 0,
    string.format("Clip A start should stay anchored; expected 0, got %d", clip_a.timeline_start))
assert(clip_a.duration == 2800,
    string.format("Clip A duration should be reduced to 2800; got %d", clip_a.duration))
assert(clip_b.timeline_start == 3300,
    string.format("Clip B should shift upstream by 1200 to 3300; got %d", clip_b.timeline_start))

os.remove(DB_PATH)
print("✅ Upstream ripple shrinks clip and shifts downstream clip without DB overlap")
