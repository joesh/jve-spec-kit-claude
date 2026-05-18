-- T065 / CT-C17 (013): Nest.
--
-- Per FR-010 / commands.md §Nest:
--   Args: { sequence_id, selected_clip_ids }
--     sequence_id MUST reference a kind='sequence' sequence (rule 2.29).
--     all selected_clip_ids MUST belong to that sequence.
--
--   Mutation:
--     1. Create new sequence S with kind='sequence' (timebase + dimensions
--        copied from the parent).
--     2. Create matching tracks on S for each track_type/track_index of
--        the selected clips.
--     3. Move each selected clip into S: owner_sequence_id ← S;
--        track_id ← S's equivalent track; sequence_start_frame
--        translated by -min_selected_start so clips are relative to S.
--     4. INSERT one new clip on the parent at min_selected_start, with
--        source_sequence_id = S, source_in=0, source_out=S.duration,
--        duration = the selection span.
--
-- First-landing scope: all selected clips must be on the same track.
-- Multi-track nesting (with one parent clip per medium, link group) is
-- a follow-up — refused with a clear message.
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_nest.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('med', 'p1', 'a.mov', '/tmp/a.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
        -- Three clips on edit V1 starting at 100, 200, 300; each 100 frames.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c1', 'p1', 'e', 'e-v1', 'm', 'c1',
                100, 100, 0, 100, NULL, 'resample', 1, 1.0, 0, 0, 0),
               ('c2', 'p1', 'e', 'e-v1', 'm', 'c2',
                200, 100, 0, 100, NULL, 'resample', 1, 1.0, 0, 0, 0),
               ('c3', 'p1', 'e', 'e-v1', 'm', 'c3',
                300, 100, 0, 100, NULL, 'resample', 1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function clips_in_sequence(db, seq_id)
    local stmt = db:prepare([[
        SELECT id, track_id, sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame, sequence_id
        FROM clips WHERE owner_sequence_id = ?
        ORDER BY sequence_start_frame ASC, id ASC
    ]])
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            sequence_start = stmt:value(2),
            duration = stmt:value(3),
            source_in = stmt:value(4),
            source_out = stmt:value(5),
            source_sequence_id = stmt:value(6),
        }
    end
    stmt:finalize()
    return rows
end

local function load_sequence_kind(db, seq_id)
    local stmt = db:prepare("SELECT kind FROM sequences WHERE id = ?")
    stmt:bind_value(1, seq_id)
    if not stmt:exec() or not stmt:next() then stmt:finalize(); return nil end
    local k = stmt:value(0)
    stmt:finalize()
    return k
end

local Nest = require("core.commands.nest")

print("-- 3 contiguous clips: parent gets 1 replacement clip; new sequence holds 3 --")
do
    build_fixture()
    local db = database.get_connection()

    local result = Nest.execute({
        sequence_id        = "e",
        selected_clip_ids  = { "c1", "c2", "c3" },
    })
    assert(result.new_sequence_id and result.new_sequence_id ~= "",
        "Nest must return new_sequence_id")
    assert(result.new_clip_id and result.new_clip_id ~= "",
        "Nest must return new_clip_id (the parent's replacement)")
    local s_id = result.new_sequence_id

    -- (1) New sequence S exists with kind='sequence'.
    assert(load_sequence_kind(db, s_id) == "sequence",
        "new sequence has kind='sequence'")

    -- (2) S contains exactly 3 clips at translated positions.
    local s_clips = clips_in_sequence(db, s_id)
    assert(#s_clips == 3,
        "new sequence holds 3 clips; got " .. tostring(#s_clips))
    -- min_start was 100; clips translated to start at [0, 100, 200).
    assert(s_clips[1].sequence_start == 0
       and s_clips[2].sequence_start == 100
       and s_clips[3].sequence_start == 200,
        "clips translated to start at 0/100/200 inside the new sequence")
    for i = 1, 3 do
        assert(s_clips[i].duration == 100, "duration preserved")
    end

    -- (3) Parent sequence E now has exactly ONE clip replacing the 3.
    local e_clips = clips_in_sequence(db, "e")
    assert(#e_clips == 1,
        "parent has 1 replacement clip; got " .. tostring(#e_clips))
    local rep = e_clips[1]
    assert(rep.id == result.new_clip_id, "result.new_clip_id matches")
    assert(rep.sequence_start == 100,
        "replacement starts at min_selected_start (100)")
    assert(rep.duration == 300,
        "replacement covers the full selection span (100..400)")
    assert(rep.source_sequence_id == s_id,
        "replacement source_sequence_id = new sequence")
    assert(rep.source_in == 0,
        "replacement source_in = 0 (start of new sequence)")
    assert(rep.source_out == 300,
        "replacement source_out = new sequence's content duration")

    print("  ok")
end

print("-- sequence_id required (rule 2.29) --")
do
    build_fixture()
    local ok = pcall(Nest.execute, {
        selected_clip_ids = { "c1" },
    })
    assert(not ok, "missing sequence_id refused")
    print("  ok")
end

print("-- master sequence as parent: refused (kind='sequence' required) --")
do
    build_fixture()
    local ok, err = pcall(Nest.execute, {
        sequence_id        = "m",
        selected_clip_ids  = { "c1" },
    })
    assert(not ok, "master parent refused")
    assert(tostring(err):find("sequence") or tostring(err):find("master"),
        "error names the kind constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- empty selection: refused --")
do
    build_fixture()
    local ok = pcall(Nest.execute, {
        sequence_id        = "e",
        selected_clip_ids  = {},
    })
    assert(not ok, "empty selection refused")
    print("  ok")
end

print("-- clip not in sequence: refused --")
do
    build_fixture()
    local ok, err = pcall(Nest.execute, {
        sequence_id        = "e",
        selected_clip_ids  = { "no-such-clip" },
    })
    assert(not ok)
    assert(tostring(err):find("not found")
        or tostring(err):find("no-such-clip"),
        "error names the missing clip; got: " .. tostring(err))
    print("  ok")
end

print("✅ test_nest.lua passed")
