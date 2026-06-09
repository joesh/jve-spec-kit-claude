#!/usr/bin/env luajit

-- Regression: gap clips in the track list allow BatchRippleEdit to
-- ripple the empty space between clips without touching media.
-- (Updated for gap-as-clip: gaps are real clips, not materialized on-the-fly.)

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local import_schema = require("import_schema")
local Clip = require("models.clip")

local DB = "/tmp/jve/test_batch_ripple_gap_materialization.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()
assert(db:exec(import_schema))

local function seed_sequence()
    local now = os.time()
    local sql = string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('proj', 'Default', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);

        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate,
            width, height, view_start_frame, view_duration_frames, playhead_frame,
            created_at, modified_at
        )
        VALUES ('seq', 'proj', 'Seq', 'sequence',
                24, 1, 48000, 1920, 1080, 0, 10000, 0, %d, %d);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);

        -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj', 'placeholder', '_placeholder', 240, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj', 'placeholder_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 240, 0, 240, 48000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('clip_left', 'proj', 'Left', 'v1', '_v13_placeholder_master', 'seq', 0, 240, 0, 240, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_right', 'proj', 'Right', 'v1', '_v13_placeholder_master', 'seq', 720, 240, 0, 240, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    ]], now, now, now, now, now, now, now, now)
    assert(db:exec(sql))
end

local function reset_db()
    assert(db:exec([[
        DELETE FROM clips;
        DELETE FROM tracks;
        DELETE FROM sequences;
        DELETE FROM projects;
    ]]))
    seed_sequence()
    command_manager.init("seq", "proj")
end

-- Gap is at [240, 720] on track v1 → gap_id = "gap_v1_240"
local GAP_ID = "gap_v1_240"

reset_db()
local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor unavailable")

-- Dry run: gap clip should appear in affected_clips
local dry_cmd = Command.create("BatchRippleEdit", "proj")
dry_cmd:set_parameter("sequence_id", "seq")
dry_cmd:set_parameter("edge_infos", {
    {clip_id = GAP_ID, edge_type = "in", track_id = "v1", trim_type = "ripple"}
})
dry_cmd:set_parameter("delta_frames", 120)
dry_cmd:set_parameter("dry_run", true)

local dry_ok, dry_payload = executor(dry_cmd)
assert(dry_ok and type(dry_payload) == "table", "BatchRippleEdit dry run failed")

-- Verify gap clip appears in preview data
local found_gap = false
for _, affected in ipairs(dry_payload.affected_clips or {}) do
    if type(affected.clip_id) == "string" and affected.clip_id:match("^gap_") then
        found_gap = true
        break
    end
end
assert(found_gap, "BatchRippleEdit should include gap clip in affected_clips during dry run")

-- Execute for real: ripple gap's in-edge by +120 → close gap, shift downstream left
local cmd = Command.create("BatchRippleEdit", "proj")
cmd:set_parameter("sequence_id", "seq")
cmd:set_parameter("edge_infos", {
    {clip_id = GAP_ID, edge_type = "in", track_id = "v1", trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", 120)

local ok, _ = executor(cmd)
assert(ok, "BatchRippleEdit gap-in ripple failed to execute")

local left = Clip.load("clip_left", db)
local right = Clip.load("clip_right", db)

assert(left ~= nil, "Left clip missing after ripple")
assert(right ~= nil, "Right clip missing after ripple")

-- Left clip stays anchored — gap ripple doesn't affect upstream media.
assert(left.sequence_start == 0, string.format("Left clip moved to %d", left.sequence_start))
assert(left.source_in == 0, "Left clip source_in should remain anchored")
assert(left.source_out == 240, "Left clip duration should not change when closing downstream gap")
assert(left.duration == 240, "Closing downstream gap must not trim the upstream clip media")

-- Downstream clip shifts upstream by delta but keeps its media range.
assert(right.sequence_start == 600,
    string.format("Right clip should shift upstream to 600, got %d", right.sequence_start))
assert(right.source_in == 0 and right.source_out == 240,
    "Right clip media bounds should stay fixed while the gap closes")

-- Reset and verify gap's out-edge: dragging right side left closes gap
reset_db()

local cmd_grow = Command.create("BatchRippleEdit", "proj")
cmd_grow:set_parameter("sequence_id", "seq")
cmd_grow:set_parameter("edge_infos", {
    {clip_id = GAP_ID, edge_type = "out", track_id = "v1", trim_type = "ripple"}
})
cmd_grow:set_parameter("delta_frames", -120)

local ok_grow = executor(cmd_grow)
assert(ok_grow, "BatchRippleEdit gap-out ripple failed to execute")

local left_after = Clip.load("clip_left", db)
local right_after = Clip.load("clip_right", db)
assert(left_after.sequence_start == 0, "Left clip should remain anchored when dragging gap out edge")
assert(right_after.sequence_start == 600,
    string.format("Dragging gap out-edge left should close the gap; expected right clip at 600, got %d", right_after.sequence_start))

os.remove(DB)
print("✅ BatchRippleEdit handles gap clips and keeps upstream media untouched")
