#!/usr/bin/env luajit

-- Updated for gap-as-clip: gap_after on clip_anchor → gap clip "in" edge

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_batch_ripple_gap_before_expand.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
local seed = string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('default_project', 'Default', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'sequence',
            1000, 1, 48000, 1920, 1080, 0, 6000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 24000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    -- V13 master sequence + track + media_ref for media1
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media1', 'default_project', 'media1_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media1', 'master_media1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media1' WHERE id = 'master_media1';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media1', 'default_project', 'master_media1', 'master_v_media1', 'media1', 0, 24000, 0, 24000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_anchor', 'default_project', 'Anchor', 'track_v1', 'master_media1', 'default_sequence', 0, 1500, 0, 1500, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_gap_target', 'default_project', 'GapTarget', 'track_v1', 'master_media1', 'default_sequence', 2500, 1000, 0, 1000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_downstream', 'default_project', 'Downstream', 'track_v1', 'master_media1', 'default_sequence', 4000, 1200, 0, 1200, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now, now, now, now, now)
assert(db:exec(seed))

command_manager.init("default_sequence", "default_project")

-- clip_anchor ends at 1500, gap is 1500..2500 → gap_id = gap_track_v1_1500
local gap_id = string.format("gap_track_v1_%d", 1500)

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "in", track_id = "track_v1"}
})
cmd:set_parameter("delta_frames", 400) -- close gap by 400 frames

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit gap expansion failed")

local target_clip = Clip.load("clip_gap_target", db)
local downstream_clip = Clip.load("clip_downstream", db)

assert(target_clip.sequence_start == 2100, string.format("Gap target should shift LEFT when gap in-edge is dragged right; expected 2100, got %s", tostring(target_clip.sequence_start)))
assert(downstream_clip.sequence_start == 3600, string.format("Downstream clip should shift by the same delta; expected 3600, got %s", tostring(downstream_clip.sequence_start)))

os.remove(TEST_DB)
print("✅ BatchRippleEdit closes gaps from upstream handles and shifts downstream clips on the same track")
