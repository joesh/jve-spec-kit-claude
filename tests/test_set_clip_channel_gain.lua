-- T050 / CT-C11 (013): SetClipChannelGain.
--
-- Domain behavior (commands.md §SetClipChannelGain):
--
-- (a) No prior override: INSERT a row materializing the inherited
--     enabled (so the clip continues to play if the master plays it)
--     with the new gain_db.
-- (b) Prior override: UPDATE gain_db only; enabled untouched.
-- (c) Undo of (a) deletes the row (back to tracking master).
-- (d) Undo of (b) restores the prior gain_db (enabled unchanged).
-- (e) sequence_id required (rule 2.29).
-- (f) channel_index out of bounds: refused (channel_index must be < master's audio channel count).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_set_clip_channel_gain.db"

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
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('med', 'p1', 'a.wav', '/tmp/a.wav', 48000, 48000, 1, 2, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-a1', 'med', 0, 48000, 0, 48000,
                1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c', 'p1', 'e', 'e-a1', 'm', 'c',
                0, 48000, 0, 48000,
                NULL, 'resample',
                1, 1.0, 0, 0, 0);
    ]]))
    return db
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

local SetClipChannelGain = require("core.commands.set_clip_channel_gain")

print("-- (a) No prior override: INSERT row with new gain --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_override(db, "c", 0) == nil, "fixture has no override")
    local capture = SetClipChannelGain.execute({
        sequence_id   = "e",
        clip_id       = "c",
        channel_index = 0,
        gain_db       = -12.0,
    })
    local row = load_override(db, "c", 0)
    assert(row, "row was inserted")
    assert(math.abs(row.gain_db - (-12.0)) < 1e-9, "gain_db = -12")
    assert(row.enabled == true, "inherited enabled (no master state row → default true)")

    -- (c) Undo deletes
    SetClipChannelGain.undo(capture)
    assert(load_override(db, "c", 0) == nil, "undo deletes the row")
    print("  ok")
end

print("-- (b) Prior override: UPDATE gain only --")
do
    build_fixture()
    local db = database.get_connection()
    -- Pre-existing override: enabled=0, gain_db=-3.
    assert(db:exec([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('c', 0, 0, -3.0)
    ]]))

    local capture = SetClipChannelGain.execute({
        sequence_id   = "e",
        clip_id       = "c",
        channel_index = 0,
        gain_db       = 6.0,
    })
    local row = load_override(db, "c", 0)
    assert(row.enabled == false, "enabled untouched")
    assert(math.abs(row.gain_db - 6.0) < 1e-9, "gain updated to +6")

    -- (d) Undo restores prior gain
    SetClipChannelGain.undo(capture)
    local restored = load_override(db, "c", 0)
    assert(restored.enabled == false, "enabled still false")
    assert(math.abs(restored.gain_db - (-3.0)) < 1e-9,
        "undo restores prior gain -3")
    print("  ok")
end

print("-- (e) sequence_id required (rule 2.29) --")
do
    build_fixture()
    local ok, err = pcall(SetClipChannelGain.execute, {
        clip_id       = "c",
        channel_index = 0,
        gain_db       = -6.0,
    })
    assert(not ok, "missing sequence_id refused")
    assert(tostring(err):find("sequence_id"), "error names the missing arg")
    print("  ok")
end

print("-- (f) channel_index out of bounds (must be < master's audio channel count) --")
do
    build_fixture()
    local ok, err = pcall(SetClipChannelGain.execute, {
        sequence_id   = "e",
        clip_id       = "c",
        channel_index = 5,
        gain_db       = -6.0,
    })
    assert(not ok, "OOB channel refused")
    assert(tostring(err):find("channel"), "error names the constraint")
    print("  ok")
end

print("✅ test_set_clip_channel_gain.lua passed")
