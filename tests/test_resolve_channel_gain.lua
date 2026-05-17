-- T023 / CT-R6 (013): channel gain composition order.
-- Master has media_refs_channel_state(ch=0, default_gain_db=-3). A clip has
-- clip_channel_override(ch=0, enabled=1, gain_db=-6). Per the override order
-- (layer → channel → gain), the clip-level override wins — effective gain for
-- channel 0 under this clip is -6 dB, not -3 dB.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_channel_gain.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-a1', 'e', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, audio_channels, audio_sample_rate, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/a.wav', 48000, 48000, 1, 2, 48000, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-a1', 'med', 0, 48000, 0, 48000, 1, 1.0, 0, 0, 0)"))
-- Master: channel 0 default gain = -3 dB.
assert(db:exec(
    "INSERT INTO media_refs_channel_state (owner_sequence_id, channel_index, enabled, default_gain_db) "
    .. "VALUES ('m', 0, 1, -3.0)"))
-- Clip A: no override — should inherit master's -3 dB on channel 0.
-- Clip B: override to -6 dB on channel 0 — should win.
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('A', 'p1', 'e', 'e-a1', 'm', 'A', 0, 48000, 0, 48000, 'passthrough', 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('B', 'p1', 'e', 'e-a1', 'm', 'B', 100000, 48000, 0, 48000, 'passthrough', 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db) "
    .. "VALUES ('B', 0, 1, -6.0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 200000, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

-- Expect 4 entries: 2 clips × 2 channels. Channel 0 under clip A reads master
-- state (-3 dB); under clip B the override wins (-6 dB).
local function find_channel(clip_id, ch)
    for _, e in ipairs(entries) do
        if e.provenance[1] == clip_id and e.channel_index == ch then return e end
    end
end

-- volume field on ResolvedEntry is the composite; test as dB by back-converting
-- the ratio via 20*log10. Allow 0.1 dB tolerance.
local function entry_gain_db(e)
    assert(e.volume and e.volume > 0, "entry volume must be > 0 for a non-disabled channel")
    return 20 * math.log10(e.volume)
end

local a0 = find_channel("A", 0)
assert(a0, "expected entry for clip A, channel 0")
local a0_db = entry_gain_db(a0)
assert(math.abs(a0_db - (-3.0)) < 0.1,
    string.format("clip A channel 0 should inherit master -3 dB; got %.2f", a0_db))

local b0 = find_channel("B", 0)
assert(b0, "expected entry for clip B, channel 0")
local b0_db = entry_gain_db(b0)
assert(math.abs(b0_db - (-6.0)) < 0.1,
    string.format("clip B channel 0 override must win with -6 dB; got %.2f", b0_db))

print("✅ test_resolve_channel_gain.lua passed")
