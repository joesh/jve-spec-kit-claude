-- T013a + T029a (013): channel_index must be < master's audio channel count.
-- clip_channel_override.channel_index pointing past the referenced nested
-- sequence's current audio channel count is rejected at resolve time with a
-- loud assert naming the clip and the bad channel_index. Not a silent skip;
-- not a silent fallback to master state.
--
-- This drives T029a (resolve-time defense-in-depth assert) and pins the
-- companion T013a model-layer behavior for ToggleClipChannel /
-- SetClipChannelGain (which already check bounds at write time —
-- regression-tested here so the model and resolver agree).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_inv5_channel_index_bounds.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- 2-channel master (one A track with audio_channels=2). Channel indices
-- 0 and 1 are valid; >= 2 is out of bounds.
local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
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
        VALUES ('a-med', 'p1', 'a.wav', '/tmp/a.wav', 200000, 48000, 1, 2, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-a', 'p1', 'm', 'm-a1', 'a-med', 0, 200000, 0, 200000,
                1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local Sequence = require("models.sequence")

print("-- T013a: ToggleClipChannel rejects channel_index >= audio channel count at write time --")
do
    build_fixture()
    local ToggleClipChannel = require("core.commands.toggle_clip_channel")
    local ok, err = pcall(ToggleClipChannel.execute, {
        sequence_id   = "e",
        clip_id       = "ca",
        channel_index = 2,    -- master has 2 channels (indices 0/1); 2 is OOB
    })
    assert(not ok, "ToggleClipChannel must refuse out-of-bounds channel_index")
    assert(tostring(err):find("INV-5") or tostring(err):find("out of bounds")
        or tostring(err):find("channel"),
        "error message names the constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- T013a: SetClipChannelGain rejects channel_index >= audio channel count at write time --")
do
    build_fixture()
    local SetClipChannelGain = require("core.commands.set_clip_channel_gain")
    local ok = pcall(SetClipChannelGain.execute, {
        sequence_id   = "e",
        clip_id       = "ca",
        channel_index = 5,
        gain_db       = -3.0,
    })
    assert(not ok, "SetClipChannelGain must refuse OOB channel_index")
    print("  ok")
end

print("-- T029a: resolver asserts on existing out-of-bounds override row (corruption / shrunk master) --")
do
    local db = build_fixture()
    -- Insert an OOB override directly via SQL (mimics a pre-existing
    -- override that became invalid because the master shrank from
    -- e.g. 4 channels to 2). FK isn't violated — the override row
    -- references the clip, not the master's track.
    assert(db:exec([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('ca', 5, 0, -6.0)
    ]]))

    local ok, err = pcall(function()
        Sequence:resolve_in_range("e", 0, 1000, {
            recursing_into = {},
            depth = 0,
            export_mode = false,
            project_fps_mismatch_policy = "passthrough",
        })
    end)
    assert(not ok, "resolver must assert on out-of-bounds channel_index override")
    assert(tostring(err):find("INV-5") or tostring(err):find("channel_index")
        or tostring(err):find("ca"),
        "channel_index out-of-bounds message must name the clip + bad channel; got: "
        .. tostring(err))
    -- Specifically the bad channel_index (5) should appear in the message.
    assert(tostring(err):find("5"),
        "message must name the offending channel_index; got: "
        .. tostring(err))
    print("  ok")
end

print("-- in-bounds override resolves cleanly (regression check) --")
do
    local db = build_fixture()
    assert(db:exec([[
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('ca', 1, 0, -6.0)
    ]]))
    local entries = Sequence:resolve_in_range("e", 0, 1000, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "passthrough",
    })
    -- 2-channel composite: 2 audio entries.
    local n_audio = 0
    for _, e in ipairs(entries) do
        if e.media_kind == "audio" then n_audio = n_audio + 1 end
    end
    assert(n_audio == 2, "in-bounds override does not break resolution")
    print("  ok")
end

print("✅ test_inv5_channel_index_bounds.lua passed")
