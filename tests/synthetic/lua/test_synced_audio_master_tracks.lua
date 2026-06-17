-- Dual-system audio: when a video clip has synced external audio (Resolve
-- AUDIO_SOURCE_CUSTOM), the mediaseq must have:
--   * Camera audio tracks: muted (disabled) — scratch audio the user replaced
--   * Synced audio tracks: NOT muted — the active audio source
--
-- Domain requirement: pressing F on a synced clip shows a full multi-track
-- mediaseq where original camera audio is disabled and external sync audio
-- is the active source. Track.muted=true IS the "disabled" state per user
-- preference feedback.
--
-- This test exercises ensure_master's synced_audio_streams opts path.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local Media    = require("models.media")
local dkjson   = require("dkjson")

local DB = "/tmp/jve/test_synced_audio_master_tracks.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'SyncTest', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
            %d, %d);
]], now, now))

-- Video media: 24fps, 2ch camera audio (stereo scratch)
-- TC origin: 01:00:00:00 at 24fps = 86400 frames; audio = 86400 * 48000/24 = 172800000 samples
local video_tc_frames  = 86400
local audio_tc_samples = 172800000
local video_media = Media.create({
    id              = "vid",
    project_id      = "p",
    name            = "A001_C001.mov",
    file_path       = "synthetic://A001_C001.mov",
    duration_frames = 240,            -- 10 seconds at 24fps
    fps_numerator   = 24,
    fps_denominator = 1,
    width = 1920, height = 1080,
    audio_channels      = 2,
    audio_sample_rate   = 48000,
    codec               = "prores",
    metadata = dkjson.encode({
        start_tc_value        = video_tc_frames, start_tc_rate = 24,
        start_tc_audio_samples = audio_tc_samples, start_tc_audio_rate = 48000,
    }),
})
assert(video_media:save())

-- External synced audio: audio-only WAV, 5 channels, 48kHz
-- Same TC origin (TC-based sync): 01:00:00:00 → 172800000 samples
-- For an audio-only file: duration = samples, frame_rate = sample_rate
local ext_audio_tc_samples  = 172800000
local ext_audio_duration_s  = 480000   -- 10 seconds * 48000 samples/sec
local ext_audio_media = Media.create({
    id              = "ext_audio",
    project_id      = "p",
    name            = "A001.wav",
    file_path       = "synthetic://A001.wav",
    duration_frames = ext_audio_duration_s,   -- samples for audio-only
    fps_numerator   = 48000,                  -- frame_rate = sample_rate for audio-only
    fps_denominator = 1,
    width = 0, height = 0,
    audio_channels    = 5,
    audio_sample_rate = 48000,
    codec             = "pcm",
    metadata = dkjson.encode({
        start_tc_audio_samples = ext_audio_tc_samples, start_tc_audio_rate = 48000,
    }),
})
assert(ext_audio_media:save())

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function query_tracks(seq_id)
    local stmt = assert(db:prepare(
        "SELECT track_type, muted, source_kind FROM tracks WHERE sequence_id = ? ORDER BY track_index"))
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local tracks = {}
    while stmt:next() do
        tracks[#tracks + 1] = {
            track_type  = stmt:value(0),
            muted       = stmt:value(1) == 1,
            source_kind = stmt:value(2),
        }
    end
    stmt:finalize()
    return tracks
end

-- ─── Test 1: without synced audio → all audio tracks NOT muted ────────────────

print("=== test_synced_audio_master_tracks.lua ===")

local plain_seq_id = Sequence.ensure_master("vid", "p")
local plain_tracks = query_tracks(plain_seq_id)

local plain_audio = {}
for _, t in ipairs(plain_tracks) do
    if t.track_type == "AUDIO" then plain_audio[#plain_audio + 1] = t end
end

assert(#plain_audio == 2, string.format(
    "plain mediaseq: expected 2 audio tracks, got %d", #plain_audio))
for i, t in ipairs(plain_audio) do
    assert(not t.muted, string.format(
        "plain mediaseq: camera audio track %d must NOT be muted (no synced audio)", i))
end
print("  ✓ Plain mediaseq: camera audio tracks not muted")

-- ─── Test 2: with synced audio → camera tracks muted, sync tracks not muted ──

-- Need a fresh video media (ensure_master is idempotent on existing master)
local video2 = Media.create({
    id              = "vid2",
    project_id      = "p",
    name            = "A001_C002.mov",
    file_path       = "synthetic://A001_C002.mov",
    duration_frames = 240,
    fps_numerator   = 24,
    fps_denominator = 1,
    width = 1920, height = 1080,
    audio_channels      = 2,
    audio_sample_rate   = 48000,
    codec               = "prores",
    metadata = dkjson.encode({
        start_tc_value        = video_tc_frames, start_tc_rate = 24,
        start_tc_audio_samples = audio_tc_samples, start_tc_audio_rate = 48000,
    }),
})
assert(video2:save())

-- One stream per synced file; one SampleOffset per channel (ext_audio = 5ch).
local synced_seq_id = Sequence.ensure_master("vid2", "p", {
    synced_audio_streams = {
        { media_id = "ext_audio", sample_offsets = { 0, 0, 0, 0, 0 } },
    },
})
local synced_tracks = query_tracks(synced_seq_id)

local synced_video_tracks = {}
local synced_camera_audio = {}
local synced_ext_audio    = {}

-- Expected layout: 1 video, 2 camera audio (muted), 5 sync audio (not muted)
for _, t in ipairs(synced_tracks) do
    if t.track_type == "VIDEO" then
        synced_video_tracks[#synced_video_tracks + 1] = t
    elseif t.source_kind == "camera" then
        synced_camera_audio[#synced_camera_audio + 1] = t
    elseif t.source_kind == "sync" then
        synced_ext_audio[#synced_ext_audio + 1] = t
    end
end

assert(#synced_video_tracks == 1, "synced mediaseq: expected 1 video track")
print("  ✓ synced mediaseq: 1 video track")

assert(#synced_camera_audio == 2, string.format(
    "synced mediaseq: expected 2 camera audio tracks, got %d", #synced_camera_audio))
for i, t in ipairs(synced_camera_audio) do
    assert(t.muted, string.format(
        "synced mediaseq: camera audio track %d must be muted (replaced by synced audio)", i))
end
print("  ✓ synced mediaseq: camera audio tracks are muted (disabled)")

assert(#synced_ext_audio == 5, string.format(
    "synced mediaseq: expected 5 synced audio tracks (5ch WAV), got %d", #synced_ext_audio))
for i, t in ipairs(synced_ext_audio) do
    assert(not t.muted, string.format(
        "synced mediaseq: synced audio track %d must NOT be muted", i))
end
print("  ✓ synced mediaseq: synced audio tracks are not muted (active source)")

-- ─── Test 3: total track count ────────────────────────────────────────────────

local total = #synced_tracks
-- 1 video + 2 camera audio + 5 synced audio = 8
assert(total == 8, string.format(
    "synced mediaseq: expected 8 total tracks (1V + 2A + 5A), got %d", total))
print("  ✓ synced mediaseq: correct total track count (1V + 2A camera + 5A sync)")

-- ─── Test 4: synced mediaseq media_refs ───────────────────────────────────────

local stmt = assert(db:prepare(
    "SELECT COUNT(*) FROM media_refs WHERE owner_sequence_id = ?"))
stmt:bind_value(1, synced_seq_id)
assert(stmt:exec()); stmt:next()
local total_refs = stmt:value(0)
stmt:finalize()

-- 1 video ref + 2 camera audio refs + 5 synced audio refs = 8
assert(total_refs == 8, string.format(
    "synced mediaseq: expected 8 media_refs (1V + 2A + 5A), got %d", total_refs))
print("  ✓ synced mediaseq: correct media_ref count (1V + 2A camera + 5A sync)")

-- ─── Test 5: multiple synced files with DIFFERENT channel counts — no track collision ─

local audio3a = Media.create({
    id = "ext3a", project_id = "p", name = "S1.wav",
    file_path = "synthetic://S1.wav", duration_frames = 480000,
    fps_numerator = 48000, fps_denominator = 1,
    width = 0, height = 0,
    audio_channels = 3, audio_sample_rate = 48000, codec = "pcm",
    metadata = dkjson.encode({
        start_tc_audio_samples = ext_audio_tc_samples, start_tc_audio_rate = 48000 }),
})
assert(audio3a:save())

local audio4 = Media.create({
    id = "ext4", project_id = "p", name = "S2.wav",
    file_path = "synthetic://S2.wav", duration_frames = 480000,
    fps_numerator = 48000, fps_denominator = 1,
    width = 0, height = 0,
    audio_channels = 4, audio_sample_rate = 48000, codec = "pcm",
    metadata = dkjson.encode({
        start_tc_audio_samples = ext_audio_tc_samples, start_tc_audio_rate = 48000 }),
})
assert(audio4:save())

local audio3b = Media.create({
    id = "ext3b", project_id = "p", name = "S3.wav",
    file_path = "synthetic://S3.wav", duration_frames = 480000,
    fps_numerator = 48000, fps_denominator = 1,
    width = 0, height = 0,
    audio_channels = 3, audio_sample_rate = 48000, codec = "pcm",
    metadata = dkjson.encode({
        start_tc_audio_samples = ext_audio_tc_samples, start_tc_audio_rate = 48000 }),
})
assert(audio3b:save())

local video3 = Media.create({
    id = "vid3", project_id = "p", name = "A001_C003.mov",
    file_path = "synthetic://A001_C003.mov",
    duration_frames = 240, fps_numerator = 24, fps_denominator = 1,
    width = 1920, height = 1080,
    audio_channels = 1, audio_sample_rate = 48000, codec = "prores",
    metadata = dkjson.encode({
        start_tc_value = video_tc_frames, start_tc_rate = 24,
        start_tc_audio_samples = audio_tc_samples, start_tc_audio_rate = 48000 }),
})
assert(video3:save())

-- If track_index formula is broken, Track.save crashes with UNIQUE constraint here.
local het_seq_id = Sequence.ensure_master("vid3", "p", {
    synced_audio_streams = {
        { media_id = "ext3a", sample_offsets = { 0, 0, 0 } },
        { media_id = "ext4",  sample_offsets = { 0, 0, 0, 0 } },
        { media_id = "ext3b", sample_offsets = { 0, 0, 0 } },
    },
})
local het_tracks = query_tracks(het_seq_id)

-- Expected: 1V + 1 cam-A + (3+4+3)=10 sync-A = 12 total
assert(#het_tracks == 12, string.format(
    "heterogeneous synced: expected 12 total tracks (1V + 1A + 10A), got %d",
    #het_tracks))

local het_audio_count = 0
local het_cam_muted_ok = true
local het_sync_unmuted_ok = true
for _, t in ipairs(het_tracks) do
    if t.track_type == "AUDIO" then
        het_audio_count = het_audio_count + 1
        if t.source_kind == "camera" then
            if not t.muted then het_cam_muted_ok = false end
        elseif t.source_kind == "sync" then
            if t.muted then het_sync_unmuted_ok = false end
        end
    end
end

assert(het_audio_count == 11, string.format(
    "heterogeneous synced: expected 11 audio tracks, got %d", het_audio_count))
assert(het_cam_muted_ok,
    "heterogeneous synced: camera audio track (index 1) must be muted")
assert(het_sync_unmuted_ok,
    "heterogeneous synced: all synced audio tracks must NOT be muted")
print("  ✓ heterogeneous synced audio (3ch+4ch+3ch): 12 tracks, correct indices, no collision")

print("✅ test_synced_audio_master_tracks.lua passed")
