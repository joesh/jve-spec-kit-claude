-- T022 / CT-R5 (013): audio channel disable override — Phase 4a (master_track_id identity).
-- A clip with clip_channel_override(master_track_id='m-a3', enabled=0) yields
-- enabled=false for the channel backed by master track m-a3 only; the channels
-- backed by m-a1, m-a2, m-a4 are unaffected.
--
-- Fixture: 4-track master (m-a1..m-a4), each track carries one channel of audio.
-- Resolver emits 4 entries, each carrying its master_track_id. Override on m-a3
-- disables the entry whose master_track_id == 'm-a3'.

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
-- Master has 4 AUDIO tracks, each carrying one channel (1-channel-per-track).
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1), "
    .. "       ('m-a2', 'm', 'A2', 'AUDIO', 2), "
    .. "       ('m-a3', 'm', 'A3', 'AUDIO', 3), "
    .. "       ('m-a4', 'm', 'A4', 'AUDIO', 4), "
    .. "       ('e-a1', 'e', 'A1', 'AUDIO', 1)"))
-- Four 1-channel media files, one per master track.
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at) "
    .. "VALUES ('med1', 'p1', 'a1.wav', '/tmp/a1.wav', 48000, 48000, 1, 1, 48000, 0, 0), "
    .. "       ('med2', 'p1', 'a2.wav', '/tmp/a2.wav', 48000, 48000, 1, 1, 48000, 0, 0), "
    .. "       ('med3', 'p1', 'a3.wav', '/tmp/a3.wav', 48000, 48000, 1, 1, 48000, 0, 0), "
    .. "       ('med4', 'p1', 'a4.wav', '/tmp/a4.wav', 48000, 48000, 1, 1, 48000, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr1', 'p1', 'm', 'm-a1', 'med1', 0, 48000, 0, 48000, 48000, 1, 1.0, 0, 0, 0), "
    .. "       ('mr2', 'p1', 'm', 'm-a2', 'med2', 0, 48000, 0, 48000, 48000, 1, 1.0, 0, 0, 0), "
    .. "       ('mr3', 'p1', 'm', 'm-a3', 'med3', 0, 48000, 0, 48000, 48000, 1, 1.0, 0, 0, 0), "
    .. "       ('mr4', 'p1', 'm', 'm-a4', 'med4', 0, 48000, 0, 48000, 48000, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-a1', 'm', 'c', 0, 48000, 0, 48000, 0, 0, 'passthrough', 1, 1.0, 0, 0, 0)"))
-- Override: master track m-a3 disabled on this clip.
assert(db:exec(
    "INSERT INTO clip_channel_override (clip_id, master_track_id, enabled, gain_db) "
    .. "VALUES ('c', 'm-a3', 0, 0.0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:pick_in_range("e", 0, 48000, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

-- Expect 4 audio entries (one per master track / channel), with the entry
-- backed by m-a3 disabled and the rest enabled.
assert(#entries == 4, "expected 4 channel entries; got " .. tostring(#entries))

-- Index entries by master_track_id (stable identity).
local by_track = {}
for _, e in ipairs(entries) do
    assert(type(e.master_track_id) == "string" and e.master_track_id ~= "",
        "every audio entry must carry master_track_id; got " .. tostring(e.master_track_id))
    by_track[e.master_track_id] = e
end
for _, tid in ipairs({"m-a1", "m-a2", "m-a3", "m-a4"}) do
    assert(by_track[tid], "missing entry for master track " .. tid)
end

-- m-a3 is the only override target (disabled). The other three must still
-- resolve to enabled — proves the override scoped to one track, not a slot.
assert(by_track["m-a3"].enabled == false,
    "master track m-a3 should be disabled by override")
for _, tid in ipairs({"m-a1", "m-a2", "m-a4"}) do
    assert(by_track[tid].enabled == true,
        "master track " .. tid .. " must remain enabled (no override)")
end

print("✅ test_resolve_channel_disable.lua passed")
