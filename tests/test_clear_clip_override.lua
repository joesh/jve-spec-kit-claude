-- T051 / CT-C12 (013): ClearClipOverride.
--
-- Per contracts/commands.md §ClearClipOverride:
--   Args: { sequence_id, clip_id, kind = 'channel'|'layer', channel_index? }.
--     channel variant DELETEs clip_channel_override(clip_id, channel_index).
--     layer variant clears clips.master_layer_track_id (sets to NULL).
--   Pre: the override exists (row, or non-NULL master_layer_track_id).
--     Calling ClearClipOverride on an absent override is refused (rule
--     2.13 — no silent no-op).
--   Undo: full prior state restored.
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_clear_clip_override.db"

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
        VALUES ('e', 'p1', 'edit', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-v2', 'm', 'V2', 'VIDEO', 2),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('med', 'p1', 'a.mov', '/tmp/a.mov', 1000, 24, 1, 2, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000,
                1, 1.0, 0, 0, 0),
               ('mr-a', 'p1', 'm', 'm-a1', 'med', 0, 1000, 0, 1000,
                1, 1.0, 0, 0, 0);
        -- Video clip with layer override = V2.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv', 'p1', 'e', 'e-v1', 'm', 'cv',
                0, 100, 0, 100,
                'm-v2', 'resample',
                1, 1.0, 0, 0, 0);
        -- Audio clip with channel-1 override (enabled=0, gain_db=-9).
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 100,
                NULL, 'resample',
                1, 1.0, 0, 0, 0);
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('ca', 1, 0, -9.0);
    ]]))
    return db
end

local function load_layer(db, clip_id)
    local stmt = db:prepare("SELECT master_layer_track_id FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next())
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

local function load_override(db, clip_id, channel_index)
    local stmt = db:prepare(
        "SELECT enabled, gain_db FROM clip_channel_override "
        .. "WHERE clip_id = ? AND channel_index = ?")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec())
    local row
    if stmt:next() then
        row = { enabled = stmt:value(0) == 1, gain_db = stmt:value(1) }
    end
    stmt:finalize()
    return row
end

local ClearClipOverride = require("core.commands.clear_clip_override")

print("-- channel: DELETE row; undo restores enabled+gain --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_override(db, "ca", 1), "fixture has override on ca/ch1")

    local capture = ClearClipOverride.execute({
        sequence_id   = "e",
        clip_id       = "ca",
        kind          = "channel",
        channel_index = 1,
    })
    assert(load_override(db, "ca", 1) == nil, "row deleted")

    ClearClipOverride.undo(capture)
    local restored = load_override(db, "ca", 1)
    assert(restored, "undo re-inserts row")
    assert(restored.enabled == false, "undo restores enabled=false")
    assert(math.abs(restored.gain_db - (-9.0)) < 1e-9,
        "undo restores gain_db=-9")
    print("  ok")
end

print("-- layer: NULL master_layer_track_id; undo restores prior id --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_layer(db, "cv") == "m-v2", "fixture has layer override V2")

    local capture = ClearClipOverride.execute({
        sequence_id = "e",
        clip_id     = "cv",
        kind        = "layer",
    })
    assert(load_layer(db, "cv") == nil, "layer cleared to NULL")

    ClearClipOverride.undo(capture)
    assert(load_layer(db, "cv") == "m-v2",
        "undo restores prior layer V2")
    print("  ok")
end

print("-- absent override is refused (rule 2.13 — no silent no-op) --")
do
    build_fixture()
    local ok, err = pcall(ClearClipOverride.execute, {
        sequence_id   = "e",
        clip_id       = "ca",
        kind          = "channel",
        channel_index = 0,  -- no override on channel 0
    })
    assert(not ok, "absent override must be refused")
    assert(tostring(err):find("override"),
        "error names the missing override; got: " .. tostring(err))
    print("  ok")
end

print("-- absent layer override is refused --")
do
    build_fixture()
    local ok, err = pcall(ClearClipOverride.execute, {
        sequence_id = "e",
        clip_id     = "ca",   -- ca has no layer override (NULL)
        kind        = "layer",
    })
    assert(not ok, "absent layer override must be refused")
    assert(tostring(err):find("layer") or tostring(err):find("override"),
        "error explains the absence; got: " .. tostring(err))
    print("  ok")
end

print("-- sequence_id required (rule 2.29) --")
do
    build_fixture()
    local ok = pcall(ClearClipOverride.execute, {
        clip_id       = "ca",
        kind          = "channel",
        channel_index = 1,
    })
    assert(not ok, "missing sequence_id refused")
    print("  ok")
end

print("-- unknown kind is refused --")
do
    build_fixture()
    local ok = pcall(ClearClipOverride.execute, {
        sequence_id = "e",
        clip_id     = "ca",
        kind        = "fps",  -- not supported
    })
    assert(not ok, "unsupported kind refused")
    print("  ok")
end

print("✅ test_clear_clip_override.lua passed")
