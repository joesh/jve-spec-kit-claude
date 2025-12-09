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
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj', 'Default', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('seq', 'proj', 'Seq', 'timeline',
            24, 1, 48000, 1920, 1080, 0, 10000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
        ('v1', 'seq', 'V1', 'VIDEO', 1, 1),
        ('v2', 'seq', 'V2', 'VIDEO', 2, 1);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_v1_upstream', 'proj', 'timeline', 'V1 Upstream', 'v1', NULL, 'seq',
         100, 480, 0, 480, 24, 1, 1, 0, %d, %d),
        ('clip_v2_left', 'proj', 'timeline', 'V2 Left', 'v2', NULL, 'seq',
         580, 240, 0, 240, 24, 1, 1, 0, %d, %d),
        ('clip_v2_right', 'proj', 'timeline', 'V2 Right', 'v2', NULL, 'seq',
         1060, 240, 0, 240, 24, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)
assert(db:exec(sql))

command_manager.init(db, "seq", "proj")

local cmd = Command.create("BatchRippleEdit", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("edge_infos", {
    {clip_id = "clip_v2_right", edge_type = "gap_before", track_id = "v2", trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", -120)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

local v1_clip = Clip.load("clip_v1_upstream", db)
local v2_right = Clip.load("clip_v2_right", db)

assert(v1_clip.timeline_start.frames == 100,
    string.format("Cross-track upstream clip moved from 100 to %d", v1_clip.timeline_start.frames))
assert(v2_right.timeline_start.frames == 940,
    string.format("V2 downstream clip should shift upstream to 940 when closing the gap; got %d", v2_right.timeline_start.frames))

os.remove(TEST_DB)
print("✅ BatchRippleEdit keeps cross-track upstream clips anchored when rippling gaps")
