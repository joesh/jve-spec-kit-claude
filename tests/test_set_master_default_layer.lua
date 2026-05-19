-- T057 / CT-C13 (013): SetMasterDefaultLayer.
--
-- Per FR-007 / commands.md §SetMasterDefaultLayer:
--   Args: { sequence_id, track_id }. sequence_id MUST reference a
--     kind='master' sequence (rule 2.29).
--   Pre: track_id belongs to sequence_id's V tracks; non-NULL (default_video_layer_track_id must be non-NULL when video tracks exist;
--     forbids NULL when the sequence has video tracks).
--   Mutation: sequences.default_video_layer_track_id = track_id.
--   Undo: prior value.
--   Signal: sequence_content_changed(sequence_id) — tracking clips
--     (master_layer_track_id IS NULL) re-resolve to the new default.
--
-- CT-C13 verifies:
--   * The column UPDATEs.
--   * A clip with NULL override re-resolves to the new default at the
--     resolver level (its played media_path follows the new V track).
--   * A clip with its own master_layer_track_id is unaffected by the
--     master-default change.
--   * Refusals: track_id from a different sequence; track_id of the
--     wrong type (audio); missing sequence_id; non-master sequence_id.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_set_master_default_layer.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);

        -- Multicam master with V1, V2, V3 (each its own media file) +
        -- one A track. Default layer = V1.
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'multicam', 'master', 24, 1, NULL, 1920, 1080, 0, 0);

        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);

        -- An "other" sequence to test cross-sequence refusal.
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('other', 'p1', 'other', 'master', 24, 1, NULL, 1920, 1080, 0, 0);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-v2', 'm', 'V2', 'VIDEO', 2),
               ('m-v3', 'm', 'V3', 'VIDEO', 3),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('other-v1', 'other', 'V1', 'VIDEO', 1);

        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        UPDATE sequences SET default_video_layer_track_id = 'other-v1' WHERE id = 'other';

        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('mv1', 'p1', 'v1.mov', '/tmp/v1.mov', 100, 24, 1, 0, 0, 0),
               ('mv2', 'p1', 'v2.mov', '/tmp/v2.mov', 100, 24, 1, 0, 0, 0),
               ('mv3', 'p1', 'v3.mov', '/tmp/v3.mov', 100, 24, 1, 0, 0, 0);

        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v1', 'p1', 'm', 'm-v1', 'mv1', 0, 100, 0, 100, 48000, 1, 1.0, 0, 0, 0),
               ('mr-v2', 'p1', 'm', 'm-v2', 'mv2', 0, 100, 0, 100, 48000, 1, 1.0, 0, 0, 0),
               ('mr-v3', 'p1', 'm', 'm-v3', 'mv3', 0, 100, 0, 100, 48000, 1, 1.0, 0, 0, 0);

        -- Clip 'tracking' with master_layer_track_id NULL (inherits master default).
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('tracking', 'p1', 'e', 'e-v1', 'm', 'tracking',
                0, 100, 0, 100, NULL, 'resample',
                1, 1.0, 0, 0, 0);

        -- Clip 'overridden' with explicit V3.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('overridden', 'p1', 'e', 'e-v1', 'm', 'overridden',
                500, 100, 0, 100, 'm-v3', 'resample',
                1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function load_default_layer(db, seq_id)
    local stmt = db:prepare("SELECT default_video_layer_track_id FROM sequences WHERE id = ?")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec() and stmt:next())
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

local function media_path_for_clip(seq_id, clip_id)
    local Sequence = require("models.sequence")
    local entries = Sequence:pick_in_range(seq_id, 0, 100000, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "resample",
    })
    for _, e in ipairs(entries) do
        if e.provenance[1] == clip_id then return e.media_path end
    end
    return nil
end

local SetMasterDefaultLayer = require("core.commands.set_master_default_layer")

print("-- happy path: V1 → V2 changes column AND tracking clip's media path --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_default_layer(db, "m") == "m-v1")
    assert(media_path_for_clip("e", "tracking") == "/tmp/v1.mov",
        "tracking clip plays V1 before the change")
    assert(media_path_for_clip("e", "overridden") == "/tmp/v3.mov",
        "overridden clip plays V3 (its own override)")

    local capture = SetMasterDefaultLayer.execute({
        sequence_id = "m",
        track_id    = "m-v2",
    })
    assert(load_default_layer(db, "m") == "m-v2", "column flips to V2")
    assert(media_path_for_clip("e", "tracking") == "/tmp/v2.mov",
        "tracking clip now plays V2")
    assert(media_path_for_clip("e", "overridden") == "/tmp/v3.mov",
        "overridden clip is unaffected by master-default change")

    SetMasterDefaultLayer.undo(capture)
    assert(load_default_layer(db, "m") == "m-v1", "undo restores V1")
    assert(media_path_for_clip("e", "tracking") == "/tmp/v1.mov",
        "tracking clip plays V1 again after undo")
    print("  ok")
end

print("-- track_id from a different sequence: refused --")
do
    build_fixture()
    local ok, err = pcall(SetMasterDefaultLayer.execute, {
        sequence_id = "m",
        track_id    = "other-v1",
    })
    assert(not ok)
    assert(tostring(err):find("sequence") or tostring(err):find("track"),
        "error names the constraint")
    print("  ok")
end

print("-- audio track refused (master.default_video_layer_track_id) --")
do
    build_fixture()
    local ok, err = pcall(SetMasterDefaultLayer.execute, {
        sequence_id = "m",
        track_id    = "m-a1",
    })
    assert(not ok)
    assert(tostring(err):lower():find("video") or tostring(err):find("track_type"),
        "error names V-track constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- missing sequence_id: refused (rule 2.29) --")
do
    build_fixture()
    local ok = pcall(SetMasterDefaultLayer.execute, { track_id = "m-v2" })
    assert(not ok)
    print("  ok")
end

print("-- non-master sequence_id: refused --")
do
    build_fixture()
    local ok, err = pcall(SetMasterDefaultLayer.execute, {
        sequence_id = "e",
        track_id    = "e-v1",
    })
    assert(not ok)
    assert(tostring(err):find("master"),
        "error names the kind constraint; got: " .. tostring(err))
    print("  ok")
end

print("✅ test_set_master_default_layer.lua passed")
