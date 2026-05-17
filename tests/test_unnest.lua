-- T066 + T067 / CT-C18 + CT-C19 (013): Unnest.
--
-- Per FR-010 / commands.md §Unnest:
--   Args: { sequence_id, clip_id }. sequence_id is the clip's
--     owner_sequence_id (rule 2.29).
--   Pre: clip exists; clip.source_sequence_id.kind == 'sequence'.
--     Masters CANNOT be unnested (their tracks hold media_refs which
--     can't live in a kind='sequence' sequence).
--   Mutation:
--     1. For each clip C inside clip.source_sequence_id: UPDATE
--        owner_sequence_id ← parent; track_id ← parent's equivalent
--        track; sequence_start_frame ← C.sequence_start_frame +
--        (clip.sequence_start_frame - clip.source_in_frame).
--     2. DELETE the clip row.
--     3. If the nested sequence has no remaining references, DELETE it
--        (orphan cleanup).
--
-- CT-C18: 3 clips inside the nested expand back at translated positions;
--         unnested clip row is gone; nested sequence is orphan-deleted.
-- CT-C19: Unnest on a clip whose nested.kind='master' is refused.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_unnest.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_master_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med', 'p1', 'a.mov', '/tmp/a.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
        -- Clip on edit referencing the master directly.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-master', 'p1', 'e', 'e-v1', 'm', 'on master',
                100, 100, 0, 100, NULL, 'resample', 1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function build_nested_fixture()
    -- Mirror the Nest fixture, then run Nest to produce a nested sequence
    -- in a known state that we can Unnest.
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med', 'p1', 'a.mov', '/tmp/a.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
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
    local Nest = require("core.commands.nest")
    local r = Nest.execute({
        sequence_id        = "e",
        selected_clip_ids  = { "c1", "c2", "c3" },
    })
    return db, r
end

local function clips_in_sequence(db, seq_id)
    local stmt = db:prepare([[
        SELECT id, sequence_start_frame, duration_frames
        FROM clips WHERE owner_sequence_id = ?
        ORDER BY sequence_start_frame ASC, id ASC
    ]])
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            sequence_start = stmt:value(1),
            duration = stmt:value(2),
        }
    end
    stmt:finalize()
    return rows
end

local function sequence_exists(db, id)
    local stmt = db:prepare("SELECT 1 FROM sequences WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec())
    local found = stmt:next()
    stmt:finalize()
    return found
end

local Unnest = require("core.commands.unnest")

print("-- CT-C19 refusal: clip whose nested.kind='master' --")
do
    build_master_fixture()
    local ok, err = pcall(Unnest.execute, {
        sequence_id = "e",
        clip_id     = "c-master",
    })
    assert(not ok, "Unnest on master must refuse")
    assert(tostring(err):find("master") or tostring(err):find("sequence"),
        "error names the kind constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- CT-C18: expansion + orphan delete --")
do
    local db, nest_result = build_nested_fixture()
    -- After Nest: parent has one clip (the replacement) at sequence_start=100,
    -- duration=300; nested sequence has 3 clips at 0/100/200 of duration 100.
    assert(#clips_in_sequence(db, "e") == 1)
    assert(#clips_in_sequence(db, nest_result.new_sequence_id) == 3)

    local result = Unnest.execute({
        sequence_id = "e",
        clip_id     = nest_result.new_clip_id,
    })

    -- Parent now has 3 clips at translated positions.
    local e_clips = clips_in_sequence(db, "e")
    assert(#e_clips == 3, string.format(
        "parent should hold 3 clips after unnest; got %d", #e_clips))
    assert(e_clips[1].sequence_start == 100
       and e_clips[2].sequence_start == 200
       and e_clips[3].sequence_start == 300,
        "clips translated back to original 100/200/300")

    -- Original replacement clip is gone.
    for _, r in ipairs(e_clips) do
        assert(r.id ~= nest_result.new_clip_id,
            "replacement clip id was deleted")
    end

    -- Nested sequence orphan-deleted.
    assert(not sequence_exists(db, nest_result.new_sequence_id),
        "nested sequence is orphan-deleted (no other refs)")
    assert(result.orphan_deleted == true,
        "result.orphan_deleted reports the cleanup")
    print("  ok")
end

print("-- still-referenced nested sequence is NOT orphan-deleted --")
do
    local db, nest_result = build_nested_fixture()
    -- Add a second referencing clip to the nested.
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-keep', 'p1', 'e', 'e-v1', '%s', 'keep',
                500, 300, 0, 300, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]], nest_result.new_sequence_id)))

    local result = Unnest.execute({
        sequence_id = "e",
        clip_id     = nest_result.new_clip_id,
    })

    assert(sequence_exists(db, nest_result.new_sequence_id),
        "nested sequence kept (still referenced by c-keep)")
    assert(result.orphan_deleted == false,
        "result.orphan_deleted = false")
    print("  ok")
end

print("-- sequence_id mismatch refused (rule 2.29) --")
do
    local _, nest_result = build_nested_fixture()
    local ok = pcall(Unnest.execute, {
        sequence_id = "m",  -- not the clip's owner
        clip_id     = nest_result.new_clip_id,
    })
    assert(not ok)
    print("  ok")
end

print("✅ test_unnest.lua passed")
