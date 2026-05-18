-- 018 INV-3 inline subframe migration applied (count=1)
-- T058 / CT-C14 (013): SetMasterChannelState.
--
-- Per FR-006 / FR-007 / commands.md §SetMasterChannelState:
--   Args: { sequence_id, channel_index, enabled, gain_db }.
--     sequence_id is the master being mutated (rule 2.29).
--   Pre: sequence_id.kind='master'; channel_index < master's audio
--     channel count; enabled and gain_db both required (rule 2.13 —
--     the row carries explicit values, never relies on a SQL DEFAULT).
--   Mutation: UPSERT media_refs_channel_state(sequence_id, channel_index)
--     with the new (enabled, default_gain_db).
--   Undo: prior row state, or row-absence sentinel.
--   Signal: sequence_content_changed(sequence_id) — every clip that has
--     NOT overridden this channel re-resolves to the new master state.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_set_master_channel_state.db"

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
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('med', 'p1', 'a.wav', '/tmp/a.wav', 48000, 48000, 1, 4, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-a1', 'med', 0, 48000, 0, 48000,
                1, 1.0, 0, 0, 0);
        -- Two clips: one without override, one with override on channel 1.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('tracking', 'p1', 'e', 'e-a1', 'm', 'tracking',
                0, 48000, 0, 48000, 0, 0, NULL, 'resample',
                1, 1.0, 0, 0, 0),
               ('overridden', 'p1', 'e', 'e-a1', 'm', 'overridden',
                100000, 48000, 0, 48000, NULL, 'resample',
                1, 1.0, 0, 0, 0);
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('overridden', 1, 1, 0.0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function load_master_state(db, seq_id, ch)
    local stmt = db:prepare(
        "SELECT enabled, default_gain_db FROM media_refs_channel_state "
        .. "WHERE owner_sequence_id = ? AND channel_index = ?")
    stmt:bind_value(1, seq_id)
    stmt:bind_value(2, ch)
    assert(stmt:exec())
    local r
    if stmt:next() then
        r = { enabled = stmt:value(0) == 1, gain_db = stmt:value(1) }
    end
    stmt:finalize()
    return r
end

local SetMasterChannelState = require("core.commands.set_master_channel_state")

print("-- INSERT new row; undo deletes --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_master_state(db, "m", 2) == nil,
        "fixture has no master state row on channel 2")

    local capture = SetMasterChannelState.execute({
        sequence_id   = "m",
        channel_index = 2,
        enabled       = false,
        gain_db       = -6.0,
    })
    local row = load_master_state(db, "m", 2)
    assert(row and row.enabled == false
        and math.abs(row.gain_db - (-6.0)) < 1e-9,
        "row inserted with explicit values")

    SetMasterChannelState.undo(capture)
    assert(load_master_state(db, "m", 2) == nil, "undo deletes the row")
    print("  ok")
end

print("-- UPDATE existing row; undo restores prior --")
do
    build_fixture()
    local db = database.get_connection()
    assert(db:exec([[
        INSERT INTO media_refs_channel_state
            (owner_sequence_id, channel_index, enabled, default_gain_db)
        VALUES ('m', 0, 1, -3.0)
    ]]))
    local capture = SetMasterChannelState.execute({
        sequence_id   = "m",
        channel_index = 0,
        enabled       = true,
        gain_db       = 6.0,
    })
    local row = load_master_state(db, "m", 0)
    assert(row.enabled == true and math.abs(row.gain_db - 6.0) < 1e-9,
        "row updated to (true, 6)")

    SetMasterChannelState.undo(capture)
    local restored = load_master_state(db, "m", 0)
    assert(restored.enabled == true
        and math.abs(restored.gain_db - (-3.0)) < 1e-9,
        "undo restores prior (true, -3)")
    print("  ok")
end

print("-- non-master sequence: refused --")
do
    build_fixture()
    local ok, err = pcall(SetMasterChannelState.execute, {
        sequence_id   = "e",
        channel_index = 0,
        enabled       = true,
        gain_db       = 0.0,
    })
    assert(not ok)
    assert(tostring(err):find("master"),
        "error names the kind constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- channel_index out of bounds: refused (channel_index must be < master's audio channel count) --")
do
    build_fixture()
    local ok, err = pcall(SetMasterChannelState.execute, {
        sequence_id   = "m",
        channel_index = 99,
        enabled       = true,
        gain_db       = 0.0,
    })
    assert(not ok)
    assert(tostring(err):find("channel"),
        "error names the bounds; got: " .. tostring(err))
    print("  ok")
end

print("-- enabled is required (rule 2.13) --")
do
    build_fixture()
    local ok = pcall(SetMasterChannelState.execute, {
        sequence_id   = "m",
        channel_index = 0,
        gain_db       = 0.0,
    })
    assert(not ok, "missing enabled refused")
    print("  ok")
end

print("-- gain_db is required (rule 2.13) --")
do
    build_fixture()
    local ok = pcall(SetMasterChannelState.execute, {
        sequence_id   = "m",
        channel_index = 0,
        enabled       = true,
    })
    assert(not ok, "missing gain_db refused")
    print("  ok")
end

print("✅ test_set_master_channel_state.lua passed")
