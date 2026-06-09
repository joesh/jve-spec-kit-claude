-- NSF regression: Duplicate on an AUDIO clip must preserve subframes
-- on the new clip. Exercises clip_mutator.plan_duplicate_block →
-- build_duplicated_clip (the third of three in-mutator row builders
-- identified in the Cat F NSF extension).

require("test_env")

local database = require("core.database")
local clip_mutator = require("core.clip_mutator")
local command_helper = require("core.command_helper")

local db_path = "/tmp/jve/test_audio_duplicate_preserves_subframes.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

local SRC_IN_SUBFRAME  = 4567
local SRC_OUT_SUBFRAME = 1234

assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":25,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, playhead_frame, view_start_frame, view_duration_frames,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq', 'proj', 'Timeline', 'sequence', 25, 1, 48000, 1920, 1080,
        0, 0, 8000, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master_med', 'proj', 'med_master', 'master', 25, 1, NULL, NULL, NULL, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('master_a_med', 'master_med', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('orig', 'proj', 'Original', 'a1', 'seq', 'master_med',
        100, 200, 50, 250, %d, %d, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, SRC_IN_SUBFRAME, SRC_OUT_SUBFRAME, now, now)))

-- Duplicate the clip with +400 frame delta → new clip at frame 500.
local DELTA = 400
local ok_plan, plan_err, plan = clip_mutator.plan_duplicate_block(db, {
    sequence_id     = "seq",
    clip_ids        = { "orig" },
    delta_frames    = DELTA,
    target_track_id = "a1",
    anchor_clip_id  = "orig",
})
assert(ok_plan, "plan_duplicate_block failed: " .. tostring(plan_err))
assert(plan and plan.planned_mutations and #plan.planned_mutations > 0,
    "expected at least one planned mutation")

local apply_ok, apply_err = command_helper.apply_mutations(db, plan.planned_mutations)
assert(apply_ok, "apply_mutations failed: " .. tostring(apply_err))

-- New clip should land at sequence_start = 500 carrying the same
-- subframes as the original.
local stmt = db:prepare([[
    SELECT id, sequence_start_frame, source_in_subframe, source_out_subframe
    FROM clips WHERE owner_sequence_id = 'seq' AND sequence_start_frame = 500
]])
assert(stmt:exec() and stmt:next(), "duplicate clip should exist at frame 500")
local dup_id      = stmt:value(0)
local dup_in_sub  = stmt:value(2)
local dup_out_sub = stmt:value(3)
stmt:finalize()

assert(dup_in_sub == SRC_IN_SUBFRAME, string.format(
    "duplicate source_in_subframe = %s, want %d (build_duplicated_clip dropped subframe)",
    tostring(dup_in_sub), SRC_IN_SUBFRAME))
assert(dup_out_sub == SRC_OUT_SUBFRAME, string.format(
    "duplicate source_out_subframe = %s, want %d (build_duplicated_clip dropped subframe)",
    tostring(dup_out_sub), SRC_OUT_SUBFRAME))

print("✅ test_audio_duplicate_preserves_subframes passed (dup_id=" .. dup_id .. ")")
