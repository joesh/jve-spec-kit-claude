-- T023 / CT-R6 (013): channel gain composition order — Phase 4a (master_track_id identity).
-- Master has media_refs_channel_state(master_track_id='m-a1', default_gain_db=-3).
-- A clip has clip_channel_override(master_track_id='m-a1', enabled=1, gain_db=-6).
-- Per the override order (layer → channel → gain), the clip-level override wins —
-- effective gain for the channel backed by m-a1 under this clip is -6 dB, not -3 dB.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_channel_gain.db"
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
-- Two master AUDIO tracks so the 2-channel media resolves to two entries.
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1), "
    .. "       ('m-a2', 'm', 'A2', 'AUDIO', 2), "
    .. "       ('e-a1', 'e', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/a.wav', 48000, 48000, 1, 2, 48000, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-a1', 'med', 0, 48000, 0, 48000, 48000, 1, 1.0, 0, 0, 0)"))
-- Master channel state: track m-a1 default gain = -3 dB.
assert(db:exec(
    "INSERT INTO media_refs_channel_state (master_track_id, enabled, default_gain_db) "
    .. "VALUES ('m-a1', 1, -3.0)"))
-- Clip A: no override — should inherit master's -3 dB on the m-a1 channel.
-- Clip B: override on m-a1 to -6 dB — should win.
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('A', 'p1', 'e', 'e-a1', 'm', 'A', 0, 48000, 0, 48000, 0, 0, 'passthrough', 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('B', 'p1', 'e', 'e-a1', 'm', 'B', 100000, 48000, 0, 48000, 0, 0, 'passthrough', 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clip_channel_override (clip_id, master_track_id, enabled, gain_db) "
    .. "VALUES ('B', 'm-a1', 1, -6.0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:pick_in_range("e", 0, 200000, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

-- 2-channel composite ref on m-a1 fans to two entries per clip; both share
-- master_track_id='m-a1'. The channel backed by m-a1 under clip A reads
-- master state (-3 dB); under clip B the override wins (-6 dB).
local function find_track_entry(clip_id, master_track_id)
    for _, e in ipairs(entries) do
        if e.provenance[1] == clip_id and e.master_track_id == master_track_id then
            return e
        end
    end
end

-- volume field on ResolvedEntry is the composite; test as dB by back-converting
-- the ratio via 20*log10. Allow 0.1 dB tolerance.
local function entry_gain_db(e)
    assert(e.volume and e.volume > 0, "entry volume must be > 0 for a non-disabled channel")
    return 20 * math.log10(e.volume)
end

local a_m_a1 = find_track_entry("A", "m-a1")
assert(a_m_a1, "expected entry for clip A on master track m-a1")
local a_db = entry_gain_db(a_m_a1)
assert(math.abs(a_db - (-3.0)) < 0.1,
    string.format("clip A m-a1 should inherit master -3 dB; got %.2f", a_db))

local b_m_a1 = find_track_entry("B", "m-a1")
assert(b_m_a1, "expected entry for clip B on master track m-a1")
local b_db = entry_gain_db(b_m_a1)
assert(math.abs(b_db - (-6.0)) < 0.1,
    string.format("clip B m-a1 override must win with -6 dB; got %.2f", b_db))

print("✅ test_resolve_channel_gain.lua passed")
