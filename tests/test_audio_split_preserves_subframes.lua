-- NSF regression: an AUDIO clip split by the mutator pipeline must
-- preserve subframes on BOTH halves. Same bug class as Cat F (Paste) —
-- the in-mutator split row builders (resolve_occlusions straddle split,
-- resolve_occlusions_multi split, resolve_ripple split, build_duplicated_clip)
-- previously omitted source_in_subframe / source_out_subframe, which the
-- V11 schema trigger would catch with an opaque SQL message OR pass
-- silently if the trigger evaluation order shifted.
--
-- Black-box: overwrite a NEW audio clip on top of an existing one that
-- straddles the overwrite span. The straddle splits the existing clip
-- into left + right halves; both halves must carry the original's
-- subframes (the split happens at frame boundary; sub-frame fractional
-- component is unchanged on both sides).

require("test_env")

local database = require("core.database")
local clip_mutator = require("core.clip_mutator")

local db_path = "/tmp/jve/test_audio_split_preserves_subframes.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Master clock 192000 / 25fps → 7680 ticks/frame. Pick non-zero mid-frame
-- subframes that no implementation would generate by accident.
local SRC_IN_SUBFRAME  = 2345
local SRC_OUT_SUBFRAME = 6789

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

-- Drive a straddle split by carving out [200, 250) on track a1 — the
-- existing clip will be split into left [100,200) + right [250,400).
local ok, err, mutations = clip_mutator.resolve_occlusions(db, {
    track_id       = "a1",
    sequence_start = 200,
    duration       = 50,
})
assert(ok, "resolve_occlusions failed: " .. tostring(err))
assert(mutations and #mutations > 0, "expected at least one mutation")

-- Apply.
local command_helper = require("core.command_helper")
local apply_ok, apply_err = command_helper.apply_mutations(db, mutations)
assert(apply_ok, "apply_mutations failed: " .. tostring(apply_err))

-- Both halves must carry the original's subframes.
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

assert(#rows == 2, string.format("expected 2 clips after split, got %d", #rows))
for _, r in ipairs(rows) do
    assert(r.in_sub == SRC_IN_SUBFRAME, string.format(
        "clip @ %d: source_in_subframe = %s, want %d (in-mutator split dropped subframe)",
        r.start, tostring(r.in_sub), SRC_IN_SUBFRAME))
    assert(r.out_sub == SRC_OUT_SUBFRAME, string.format(
        "clip @ %d: source_out_subframe = %s, want %d (in-mutator split dropped subframe)",
        r.start, tostring(r.out_sub), SRC_OUT_SUBFRAME))
end

print("✅ test_audio_split_preserves_subframes passed (left+right both keep subframes)")
