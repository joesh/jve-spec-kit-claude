-- T003a (013): clips.master_audio_track_id column shape.
--
-- Per FR-005 / FR-023 / FR-024 + data-model.md:
--   * The column exists as TEXT, nullable, FK to tracks(id) with
--     ON DELETE SET NULL.
--   * NULL = composite (today's behavior — clip plays all audio tracks
--     of source_sequence_id mixed).
--   * Non-NULL = "single audio track" — clip exposes one specific A
--     track of source_sequence_id (symmetric to master_layer_track_id
--     for video).
--   * On track delete, the column resets to NULL (the override is an
--     optional interpretation; if its target disappears, fall back to
--     composite per the FK action).
--
-- Black-box DB-state assertions; bypass model layer to verify the raw
-- schema invariants.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_clips_master_audio_track_id.db"

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
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-a2', 'm', 'A2', 'AUDIO', 2),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
    ]]))
    return db
end

local function load_audio_track(db, clip_id)
    local stmt = db:prepare("SELECT master_audio_track_id FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next())
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

print("-- column exists; NULL accepted (composite default) --")
do
    local db = build_fixture()
    -- Clip with master_audio_track_id NULL (composite — today's behavior).
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-comp', 'p1', 'e', 'e-a1', 'm', 'composite',
                0, 100, 0, 100,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0)
    ]]), "INSERT with master_audio_track_id=NULL must succeed (composite)")
    assert(load_audio_track(db, "c-comp") == nil,
        "NULL persists as NULL")
    print("  ok")
end

print("-- non-NULL accepted; FK references tracks(id) --")
do
    local db = build_fixture()
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-exp', 'p1', 'e', 'e-a1', 'm', 'expanded-A2',
                0, 100, 0, 100,
                NULL, 'm-a2', 'passthrough',
                1, 1.0, 0, 0, 0)
    ]]), "INSERT with master_audio_track_id='m-a2' must succeed")
    assert(load_audio_track(db, "c-exp") == "m-a2",
        "non-NULL persists as the track id")
    print("  ok")
end

print("-- FK rejects bogus track id --")
do
    local db = build_fixture()
    local stmt = db:prepare([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-bad', 'p1', 'e', 'e-a1', 'm', 'bad',
                0, 100, 0, 100,
                NULL, 'no-such-track', 'passthrough',
                1, 1.0, 0, 0, 0)
    ]])
    assert(stmt)
    local ok = stmt:exec()
    local err = (not ok) and stmt:last_error() or nil
    stmt:finalize()
    assert(not ok,
        "INSERT with non-existent master_audio_track_id must violate FK")
    assert(tostring(err):lower():find("foreign key"),
        "error must name the FK violation; got: " .. tostring(err))
    print("  ok")
end

print("-- ON DELETE SET NULL: deleting the referenced track NULLs the column --")
do
    local db = build_fixture()
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-pin', 'p1', 'e', 'e-a1', 'm', 'pinned-A2',
                0, 100, 0, 100,
                NULL, 'm-a2', 'passthrough',
                1, 1.0, 0, 0, 0)
    ]]))
    assert(load_audio_track(db, "c-pin") == "m-a2",
        "fixture pre-state: master_audio_track_id = m-a2")

    assert(db:exec("DELETE FROM tracks WHERE id = 'm-a2'"),
        "DELETE the referenced track")

    assert(load_audio_track(db, "c-pin") == nil,
        "ON DELETE SET NULL: column reset to NULL after track delete")
    print("  ok")
end

print("✅ test_schema_clips_master_audio_track_id.lua passed")
