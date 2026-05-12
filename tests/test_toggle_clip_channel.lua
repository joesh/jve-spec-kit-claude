-- T049 / CT-C10 (013): ToggleClipChannel.
--
-- Domain behavior (commands.md §ToggleClipChannel):
--
-- (a) First toggle on a clip with no override row materializes the
--     inherited state and flips enabled. Concretely: master channel 2
--     is enabled with gain -3 dB; first ToggleClipChannel(c, 2) inserts
--     clip_channel_override(c, 2, enabled=0, gain_db=-3).
--
-- (b) Undo of first toggle DELETES the override row (back to
--     "tracking master").
--
-- (c) Second toggle on a clip with an override row flips enabled
--     in-place; gain_db unchanged. Undo restores prior enabled value.
--
-- (d) sequence_id arg is required (rule 2.29 regression).
--
-- (e) channel_index out of bounds (master has 2 audio channels, attempt
--     channel 5) is refused with a loud message naming the bad index
--     (FR-014 + channel_index must be < master's audio channel count).
--
-- Black-box: tests inspect clip_channel_override rows directly.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_toggle_clip_channel.db"

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
        UPDATE sequences SET default_video_layer_track_id = NULL WHERE id = 'm';

        -- Master has 2 audio channels (encoded in media.audio_channels).
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

        -- Master-level channel state: channel 2 enabled with -3 dB
        -- (channel_index=1 since the index is 0-based per data-model.md).
        INSERT INTO media_refs_channel_state
            (owner_sequence_id, channel_index, enabled, default_gain_db)
        VALUES ('m', 1, 1, -3.0);

        -- The clip on the edit timeline references the master.
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
    local stmt = db:prepare([[
        SELECT enabled, gain_db FROM clip_channel_override
        WHERE clip_id = ? AND channel_index = ?
    ]])
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "load_override exec failed")
    local row
    if stmt:next() then
        row = { enabled = stmt:value(0) == 1, gain_db = stmt:value(1) }
    end
    stmt:finalize()
    return row
end

-- TDD gate: this fails until T054 lands toggle_clip_channel.lua.
local ToggleClipChannel = require("core.commands.toggle_clip_channel")

print("-- (a) First toggle materializes inherited state, flips enabled --")
do
    build_fixture()
    local db = database.get_connection()
    assert(load_override(db, "c", 1) == nil,
        "fixture clip starts with no override row on channel 1")

    local capture = ToggleClipChannel.execute({
        sequence_id   = "e",
        clip_id       = "c",
        channel_index = 1,
    })

    local row = load_override(db, "c", 1)
    assert(row, "first toggle must INSERT an override row")
    assert(row.enabled == false, string.format(
        "first toggle materializes inherited (enabled=true) and flips it; "
        .. "expected enabled=false, got %s", tostring(row.enabled)))
    assert(math.abs(row.gain_db - (-3.0)) < 1e-9, string.format(
        "first toggle materializes the master-level gain (-3 dB); got %s",
        tostring(row.gain_db)))

    -- (b) Undo deletes the row (restoring "tracking master").
    ToggleClipChannel.undo(capture)
    assert(load_override(db, "c", 1) == nil,
        "undo of first toggle deletes the override row")
    print("  ok")
end

print("-- (c) Second toggle on existing override flips enabled in-place --")
do
    build_fixture()
    local db = database.get_connection()
    -- Pre-existing override: enabled=0, gain_db=-6.
    assert(db:exec([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('c', 1, 0, -6.0)
    ]]))

    local capture = ToggleClipChannel.execute({
        sequence_id   = "e",
        clip_id       = "c",
        channel_index = 1,
    })

    local row = load_override(db, "c", 1)
    assert(row, "row must remain after toggle")
    assert(row.enabled == true,
        "toggle flips existing enabled=0 to enabled=1")
    assert(math.abs(row.gain_db - (-6.0)) < 1e-9,
        "toggle does not touch gain_db on an existing row")

    ToggleClipChannel.undo(capture)
    local restored = load_override(db, "c", 1)
    assert(restored and restored.enabled == false
        and math.abs(restored.gain_db - (-6.0)) < 1e-9,
        "undo restores prior enabled=0, gain_db=-6")
    print("  ok")
end

print("-- (d) sequence_id required (rule 2.29) --")
do
    build_fixture()
    local ok, err = pcall(ToggleClipChannel.execute, {
        clip_id       = "c",
        channel_index = 1,
    })
    assert(not ok, "missing sequence_id must be refused")
    assert(tostring(err):find("sequence_id"),
        "error must name the missing arg; got: " .. tostring(err))
    print("  ok")
end

print("-- (e) channel_index out of bounds is refused (channel_index must be < master's audio channel count) --")
do
    build_fixture()
    local ok, err = pcall(ToggleClipChannel.execute, {
        sequence_id   = "e",
        clip_id       = "c",
        channel_index = 5,  -- master has 2 channels (indices 0..1)
    })
    assert(not ok, "out-of-bounds channel_index must be refused")
    assert(tostring(err):find("channel"),
        "error must name the constraint; got: " .. tostring(err))
    print("  ok")
end

print("✅ test_toggle_clip_channel.lua passed")
