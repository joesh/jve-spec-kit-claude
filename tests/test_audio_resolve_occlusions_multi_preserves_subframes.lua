-- NSF regression: resolve_occlusions_multi must preserve subframes on
-- AUDIO clip fragments when a span carved out of the middle leaves both
-- a left and a right fragment. Exercises the multi-occlusion split row
-- builder in clip_mutator (third of three in-mutator builders
-- identified in the Cat F NSF extension).

require("test_env")

local database = require("core.database")
local clip_mutator = require("core.clip_mutator")
local command_helper = require("core.command_helper")

local db_path = "/tmp/jve/test_audio_resolve_occlusions_multi_preserves_subframes.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

local SRC_IN_SUBFRAME  = 7654
local SRC_OUT_SUBFRAME = 2109

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
    -- AUDIO clip at [100, 400) with non-trivial subframes.
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('victim', 'proj', 'Victim', 'a1', 'seq', 'master_med',
        100, 300, 50, 350, %d, %d, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, SRC_IN_SUBFRAME, SRC_OUT_SUBFRAME, now, now)))

-- Carve a 50-frame span out of the middle → two surviving fragments
-- [100, 200) (left, UPDATE) + [250, 400) (right, INSERT via split_clip
-- row builder).
local ok, err, mutations = clip_mutator.resolve_occlusions_multi(db, "a1", {
    { start = 200, ["end"] = 250 },
})
assert(ok, "resolve_occlusions_multi failed: " .. tostring(err))
assert(mutations and #mutations > 0, "expected at least one mutation")

local apply_ok, apply_err = command_helper.apply_mutations(db, mutations)
assert(apply_ok, "apply_mutations failed: " .. tostring(apply_err))

-- Both surviving fragments must carry the original's subframes.
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

assert(#rows == 2, string.format(
    "expected 2 surviving fragments after multi-occlusion, got %d", #rows))
assert(rows[1].start == 100, string.format(
    "left fragment should start at 100, got %d", rows[1].start))
assert(rows[2].start == 250, string.format(
    "right fragment should start at 250, got %d", rows[2].start))

for _, r in ipairs(rows) do
    assert(r.in_sub == SRC_IN_SUBFRAME, string.format(
        "fragment @ %d: source_in_subframe = %s, want %d "
        .. "(resolve_occlusions_multi split dropped subframe)",
        r.start, tostring(r.in_sub), SRC_IN_SUBFRAME))
    assert(r.out_sub == SRC_OUT_SUBFRAME, string.format(
        "fragment @ %d: source_out_subframe = %s, want %d "
        .. "(resolve_occlusions_multi split dropped subframe)",
        r.start, tostring(r.out_sub), SRC_OUT_SUBFRAME))
end

print("✅ test_audio_resolve_occlusions_multi_preserves_subframes passed")
