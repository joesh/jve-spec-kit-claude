-- T048 / CT-C9 (013): SetClipLayer per-clip layer override.
--
-- Domain behavior:
--   * NULL → V2: clips.master_layer_track_id changes from NULL to V2's id;
--     undo restores NULL.
--   * V2 → NULL: clip override clears; undo restores V2.
--   * sequence_id arg required (rule 2.29 regression): an args table that
--     omits sequence_id is refused.
--   * track_id must belong to clip.source_sequence_id (rule 1.14): a
--     track on a DIFFERENT sequence is refused with a loud message.
--
-- Black-box DB-state assertions; bypasses command_manager for unit
-- isolation (matches the established Phase 3.4 test pattern).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_set_clip_layer.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Master multicam (V1, V2, V3) referenced by a clip on edit sequence E.
local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'multicam', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('other', 'p1', 'unrelated', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-v2', 'm', 'V2', 'VIDEO', 2),
               ('m-v3', 'm', 'V3', 'VIDEO', 3),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('other-v1', 'other', 'V1', 'VIDEO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        UPDATE sequences SET default_video_layer_track_id = 'other-v1' WHERE id = 'other';
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'C',
                0, 100, 0, 100,
                NULL, 'resample',
                1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function load_layer(db, clip_id)
    local stmt = db:prepare("SELECT master_layer_track_id FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip missing")
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

-- TDD gate: this fails until T053 lands set_clip_layer.lua.
local SetClipLayer = require("core.commands.set_clip_layer")

print("-- NULL → V2: layer override is recorded --")
do
    local db = build_fixture()
    assert(load_layer(db, "c") == nil, "fixture clip starts with NULL layer")

    local capture = SetClipLayer.execute({
        sequence_id = "e",
        clip_id     = "c",
        track_id    = "m-v2",
    })
    assert(load_layer(db, "c") == "m-v2", string.format(
        "after SetClipLayer→V2 the clip exposes V2; got %s",
        tostring(load_layer(db, "c"))))

    SetClipLayer.undo(capture)
    assert(load_layer(db, "c") == nil,
        "undo restores NULL (the inherited-default state)")
    print("  ok")
end

print("-- V2 → NULL: passing track_id=NULL clears the override --")
do
    local db = build_fixture()
    -- Pre-set V2 on the clip.
    assert(db:exec("UPDATE clips SET master_layer_track_id = 'm-v2' WHERE id = 'c'"))
    assert(load_layer(db, "c") == "m-v2", "fixture pre-set to V2")

    local capture = SetClipLayer.execute({
        sequence_id = "e",
        clip_id     = "c",
        track_id    = nil,
    })
    assert(load_layer(db, "c") == nil,
        "after SetClipLayer→NULL the clip tracks the master default")

    SetClipLayer.undo(capture)
    assert(load_layer(db, "c") == "m-v2",
        "undo restores prior V2 layer override")
    print("  ok")
end

print("-- sequence_id required (rule 2.29) --")
do
    build_fixture()
    local ok, err = pcall(SetClipLayer.execute, {
        clip_id  = "c",
        track_id = "m-v2",
    })
    assert(not ok, "missing sequence_id must be refused (rule 2.29)")
    assert(tostring(err):find("sequence_id"),
        "error must name the missing argument; got " .. tostring(err))
    print("  ok")
end

print("-- track_id must belong to clip.source_sequence_id --")
do
    build_fixture()
    local ok, err = pcall(SetClipLayer.execute, {
        sequence_id = "e",
        clip_id     = "c",
        track_id    = "other-v1",  -- belongs to a different master
    })
    assert(not ok,
        "track_id from a different sequence must be refused (G-R5 / INV-?)")
    assert(tostring(err):find("source_sequence_id")
        or tostring(err):find("track")
        or tostring(err):find("layer"),
        "error must name the bad track or the constraint; got " .. tostring(err))
    print("  ok")
end

print("✅ test_set_clip_layer.lua passed")
