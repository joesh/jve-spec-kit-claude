-- T039 (013): Insert cycle refusal.
--
-- INV-3: the containment DAG must stay acyclic. Insert refuses any
-- placement that would close a cycle — direct (sequence inside itself)
-- or transitive (E1 already contains a clip pointing to E2; inserting E1
-- into E2 would close the loop).
--
-- Refusal is loud (raises a user-visible error) and DB state is
-- unchanged: no clips row written, no clip_links row written.
--
-- Black-box: drives Insert.execute against a DB built via direct SQL
-- and verifies the clips table has zero rows after refusal.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_013_insert_cycle_refuse.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function clips_count(db)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips")
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0); stmt:finalize()
    return n
end

local function link_count(db)
    local stmt = db:prepare("SELECT COUNT(*) FROM clip_links")
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0); stmt:finalize()
    return n
end

local Insert = require("core.commands.insert")
assert(type(Insert.execute) == "function",
    "T040 not landed: core.commands.insert must export .execute")

-- -------------------------------------------------------------------------
-- Direct cycle: insert sequence E into itself.
-- -------------------------------------------------------------------------
print("-- Insert E into E refuses (direct cycle) --")
do
    local db = fresh_db()
    -- Cycle check fires before any duration / media inspection in
    -- _place_shared, so the fixture only needs the sequence + a track.
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'e', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1);
    ]]))

    local before_clips = clips_count(db)
    local before_links = link_count(db)
    local ok, err = pcall(Insert.execute, {
        sequence_id           = "e",
        nested_sequence_id    = "e",     -- same as owner — direct cycle
        timeline_start_frame  = 0,
        target_video_track_id = "e-v1",
    })
    assert(not ok, "direct cycle (E in E) must refuse")
    assert(type(err) == "string" and err:find("cycle"), string.format(
        "refusal must mention 'cycle'; got: %s", tostring(err)))
    assert(clips_count(db) == before_clips,
        "no clips row may be written on a refused cycle")
    assert(link_count(db) == before_links,
        "no clip_links row may be written on a refused cycle")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Transitive cycle: E1 already contains a clip referencing E2 (so E2 is
-- reachable from E1). Inserting E1 into E2 would close the loop.
-- -------------------------------------------------------------------------
print("-- Insert E1 into E2 refuses (transitive cycle) --")
do
    local db = fresh_db()
    -- Build a small DAG: master M with a 100-frame video media_ref, then
    -- nested E2 with a clip referencing M, then nested E1 with a clip
    -- referencing E2. Now E2 is reachable from E1 — Insert E1 into E2
    -- would close the loop.
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m',  'p1', 'm',  'master', 24, 1, 48000, 1920, 1080, 0, 0),
               ('e1', 'p1', 'e1', 'nested', 24, 1, 48000, 1920, 1080, 0, 0),
               ('e2', 'p1', 'e2', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1',  'm',  'V1', 'VIDEO', 1),
               ('e1-v1', 'e1', 'V1', 'VIDEO', 1),
               ('e2-v1', 'e2', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med', 'p1', 'v.mov', '/tmp/v.mov', 100, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-m', 'p1', 'm', 'm-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0);
        -- E2 contains a clip referencing master M (non-zero effective duration).
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('c-e2-uses-m', 'p1', 'e2', 'e2-v1', 'm', 'c2',
            0, 50, 0, 50, 'passthrough', 1, 1.0, 0, 0, 0);
        -- E1 contains a clip whose nested_sequence_id is E2 — closes the
        -- reachability E1 -> E2.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('c-e1-uses-e2', 'p1', 'e1', 'e1-v1', 'e2', 'c1',
            0, 50, 0, 50, 'passthrough', 1, 1.0, 0, 0, 0);
    ]]))

    local before_clips = clips_count(db)
    local before_links = link_count(db)
    local ok, err = pcall(Insert.execute, {
        sequence_id           = "e2",
        nested_sequence_id    = "e1",    -- e1 already references e2
        timeline_start_frame  = 0,
        target_video_track_id = "e2-v1",
    })
    assert(not ok, "transitive cycle (E1 into E2 where E1 references E2) must refuse")
    assert(type(err) == "string" and err:find("cycle"), string.format(
        "refusal must mention 'cycle'; got: %s", tostring(err)))
    assert(clips_count(db) == before_clips,
        "no clips row may be written on a refused transitive cycle")
    assert(link_count(db) == before_links,
        "no clip_links row may be written on a refused transitive cycle")
    print("  ok")
end

print("✅ test_013_insert_cycle_refuse.lua passed")
