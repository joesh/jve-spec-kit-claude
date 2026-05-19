-- T022 / CT-R5 (013): audio channel disable override.
-- A clip with clip_channel_override(clip_id, channel_index=2, enabled=0) yields
-- enabled=false for channel 2 only; other channels unaffected.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_channel_disable.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
-- Master has 4 audio channels on a single track.
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-a1', 'e', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'wav', '/tmp/x.wav', 48000, 48000, 1, 4, 48000, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-a1', 'med', 0, 48000, 0, 48000, 48000, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-a1', 'm', 'c', 0, 48000, 0, 48000, 0, 0, 'passthrough', 1, 1.0, 0, 0, 0)"))
-- Override: channel 2 disabled on this clip.
assert(db:exec(
    "INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db) "
    .. "VALUES ('c', 2, 0, 0.0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 48000, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

-- Expect 4 audio entries (one per channel), with channel 2 disabled.
assert(#entries == 4, "expected 4 channel entries; got " .. tostring(#entries))
local by_ch = {}
for _, e in ipairs(entries) do by_ch[e.channel_index] = e end
for ch = 0, 3 do
    assert(by_ch[ch], "missing entry for channel " .. ch)
    if ch == 2 then
        assert(by_ch[ch].enabled == false,
            "channel 2 should be disabled by override")
    else
        assert(by_ch[ch].enabled == true,
            "channel " .. ch .. " must remain enabled (no override)")
    end
end

print("✅ test_resolve_channel_disable.lua passed")
