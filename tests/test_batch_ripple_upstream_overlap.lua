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
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj', 'Timeline', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('seq', 'proj', 'Sequence 1', 'timeline',
            24, 1, 48000, 1920, 1080, 0, 20000, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_a', 'proj', 'timeline', 'A', 'v1', NULL, 'seq',
         0, 4000, 0, 4000, 24, 1, 1, 0, %d, %d),
        ('clip_b', 'proj', 'timeline', 'B', 'v1', NULL, 'seq',
         4500, 1500, 0, 1500, 24, 1, 1, 0, %d, %d);
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

assert(clip_a.timeline_start.frames == 0,
    string.format("Clip A start should stay anchored; expected 0, got %d", clip_a.timeline_start.frames))
assert(clip_a.duration.frames == 2800,
    string.format("Clip A duration should be reduced to 2800; got %d", clip_a.duration.frames))
assert(clip_b.timeline_start.frames == 3300,
    string.format("Clip B should shift upstream by 1200 to 3300; got %d", clip_b.timeline_start.frames))

os.remove(DB_PATH)
print("✅ Upstream ripple shrinks clip and shifts downstream clip without DB overlap")
