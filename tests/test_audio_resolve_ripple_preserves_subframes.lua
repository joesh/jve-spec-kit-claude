-- NSF regression: ExtractRange on an AUDIO clip that straddles the
-- extract range must preserve subframes on the resulting right-half.
-- Exercises clip_mutator.resolve_ripple's right_clip builder (the
-- second of three in-mutator splits identified in the Cat F NSF
-- extension; first is plan_straddle_split_actions, covered by
-- test_audio_split_preserves_subframes.lua).

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local clip_mutator = require("core.clip_mutator")
local command_helper = require("core.command_helper")

local db_path = "/tmp/jve/test_audio_resolve_ripple_preserves_subframes.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Master clock 192000 / 25fps → 7680 ticks/frame. Pick non-zero mid-frame
-- subframes that no implementation would generate by accident.
local SRC_IN_SUBFRAME  = 3141
local SRC_OUT_SUBFRAME = 4072

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
    -- Existing AUDIO clip at [100, 400) with non-trivial subframes.
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('victim', 'proj', 'Victim', 'a1', 'seq', 'master_med',
        100, 300, 50, 350, %d, %d, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, SRC_IN_SUBFRAME, SRC_OUT_SUBFRAME, now, now)))

-- Drive resolve_ripple with an insert_time inside the clip + a positive
-- shift. The clip straddles insert_time, so its left half stays and its
-- right half shifts right by shift_amount.
local INSERT_TIME  = 200
local SHIFT_AMOUNT = 50
local ok, err, mutations = clip_mutator.resolve_ripple(db, {
    track_id     = "a1",
    insert_time  = INSERT_TIME,
    shift_amount = SHIFT_AMOUNT,
})
assert(ok, "resolve_ripple failed: " .. tostring(err))
assert(mutations and #mutations > 0, "expected at least one mutation")

local apply_ok, apply_err = command_helper.apply_mutations(db, mutations)
assert(apply_ok, "apply_mutations failed: " .. tostring(apply_err))

-- After the ripple: left half should still start at 100 (shortened);
-- right half should start at insert_time + shift_amount = 250. Both must
-- carry the original's subframes.
local stmt = db:prepare([[
    SELECT id, sequence_start_frame, duration_frames,
           source_in_subframe, source_out_subframe
    FROM clips WHERE owner_sequence_id = 'seq'
    ORDER BY sequence_start_frame
]])
assert(stmt:exec(), "select failed")
local rows = {}
while stmt:next() do
    rows[#rows + 1] = {
        id        = stmt:value(0),
        start     = stmt:value(1),
        duration  = stmt:value(2),
        in_sub    = stmt:value(3),
        out_sub   = stmt:value(4),
    }
end
stmt:finalize()

assert(#rows == 2, string.format("expected 2 clips after ripple split, got %d", #rows))
assert(rows[1].start == 100, string.format("left half should start at 100, got %d", rows[1].start))
assert(rows[2].start == 250, string.format(
    "right half should start at insert_time+shift = 250, got %d", rows[2].start))

for _, r in ipairs(rows) do
    assert(r.in_sub == SRC_IN_SUBFRAME, string.format(
        "clip @ %d: source_in_subframe = %s, want %d (resolve_ripple split dropped subframe)",
        r.start, tostring(r.in_sub), SRC_IN_SUBFRAME))
    assert(r.out_sub == SRC_OUT_SUBFRAME, string.format(
        "clip @ %d: source_out_subframe = %s, want %d (resolve_ripple split dropped subframe)",
        r.start, tostring(r.out_sub), SRC_OUT_SUBFRAME))
end

print("✅ test_audio_resolve_ripple_preserves_subframes passed (both halves keep subframes)")
