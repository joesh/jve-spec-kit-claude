#!/usr/bin/env luajit

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

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                       width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 24000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_anchor', 'default_project', 'timeline', 'Anchor', 'track_v1', 'media1', 'default_sequence',
         0, 1500, 0, 1500, 1000, 1, 1, 0, %d, %d),
        ('clip_gap_target', 'default_project', 'timeline', 'GapTarget', 'track_v1', 'media1', 'default_sequence',
         2500, 1000, 0, 1000, 1000, 1, 1, 0, %d, %d),
        ('clip_downstream', 'default_project', 'timeline', 'Downstream', 'track_v1', 'media1', 'default_sequence',
         4000, 1200, 0, 1200, 1000, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now, now, now)
assert(db:exec(seed))

command_manager.init("default_sequence", "default_project")

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_anchor", edge_type = "gap_after", track_id = "track_v1"}
})
cmd:set_parameter("delta_frames", 400) -- drag [ on the upstream clip to the RIGHT should shrink the gap

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit gap expansion failed")

local target_clip = Clip.load("clip_gap_target", db)
local downstream_clip = Clip.load("clip_downstream", db)

assert(target_clip.timeline_start.frames == 2100, string.format("Gap target should shift LEFT when upstream [ is dragged right; expected 2100, got %s", tostring(target_clip.timeline_start.frames)))
assert(downstream_clip.timeline_start.frames == 3600, string.format("Downstream clip should shift by the same delta; expected 3600, got %s", tostring(downstream_clip.timeline_start.frames)))

os.remove(TEST_DB)
print("✅ BatchRippleEdit closes gaps from upstream handles and shifts downstream clips on the same track")
