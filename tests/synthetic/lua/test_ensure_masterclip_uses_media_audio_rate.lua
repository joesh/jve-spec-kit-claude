-- Regression: Sequence.ensure_master must read the audio sample rate
-- from the media record (now that media.audio_sample_rate is populated for
-- A/V files), not fall back to 48000. The previous behavior silently
-- produced incorrect audio coordinates for files at non-48kHz rates
-- (44.1kHz, 96kHz, 24kHz, etc.).
--
-- Domain behavior: an A/V media recorded at 44.1kHz must produce an audio
-- stream clip whose timebase is 44100/1 and whose source_out reflects the
-- clip's duration in 44100-Hz samples. Using the wrong rate shifts audio
-- by a few percent — inaudible for a single frame, catastrophic for any
-- sustained playback.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local Media = require("models.media")
local dkjson = require("dkjson")

print("=== test_ensure_masterclip_uses_media_audio_rate.lua ===")

local db_path = "/tmp/jve/test_ensure_masterclip_uses_media_audio_rate.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test Project', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

-- A/V file at a non-48kHz sample rate. 10 seconds of video at 25fps.
-- The audio stream is 44.1kHz stereo; 10s → 441000 samples.
local SR = 44100
local FPS = 25
local VIDEO_FRAMES = 250  -- 10 seconds

local media = Media.create({
    id = "media_av_441",
    project_id = "proj1",
    name = "AV44k",
    file_path = "synthetic://av_44k.mov",
    duration_frames = VIDEO_FRAMES,
    fps_numerator = FPS,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = SR,
    codec = "prores",
    metadata = dkjson.encode({
        start_tc_value = 0, start_tc_rate = FPS,
        start_tc_audio_samples = 0, start_tc_audio_rate = SR,
    }),
})
assert(media:save(), "Failed to save A/V media")

local mc_id = Sequence.ensure_master("media_av_441", "proj1")
assert(mc_id, "ensure_masterclip returned nil")

-- Find the audio stream clip. Stream clips have owner_sequence_id = masterclip.
-- Audio clips live on AUDIO tracks; filter by join.
-- V13: stream clips live in media_refs; their timebase derives from
-- the media's audio_sample_rate (carried on media row, not on the ref).
local stmt = assert(db:prepare([[
    SELECT m.audio_sample_rate, mr.source_in_frame, mr.source_out_frame
    FROM media_refs mr
    JOIN tracks t ON mr.track_id = t.id
    JOIN media m ON mr.media_id = m.id
    WHERE mr.owner_sequence_id = ? AND t.track_type = 'AUDIO'
    ORDER BY t.track_index
    LIMIT 1
]]))
stmt:bind_value(1, mc_id)
assert(stmt:exec())
assert(stmt:next(), "No audio stream media_ref found in master " .. mc_id)

local audio_fps_num = stmt:value(0)
local audio_fps_den = 1
local source_in = stmt:value(1)
local source_out = stmt:value(2)
stmt:finalize()

-- Expected duration in samples at the media's real sample rate.
-- 10 seconds × 44100 Hz = 441,000 samples. A 48000 fallback would
-- produce 480,000 and a timebase of 48000/1.
local EXPECTED_SR = SR
local EXPECTED_DURATION_SAMPLES = 441000

assert(audio_fps_num == EXPECTED_SR and audio_fps_den == 1, string.format(
    "audio stream clip timebase must match the media's sample rate (%d/1), got %s/%s",
    EXPECTED_SR, tostring(audio_fps_num), tostring(audio_fps_den)))
print(string.format("  ✓ audio timebase = %d/1", audio_fps_num))

assert((source_out - source_in) == EXPECTED_DURATION_SAMPLES, string.format(
    "audio duration must be %d samples (10s × %dHz), got %d",
    EXPECTED_DURATION_SAMPLES, EXPECTED_SR, source_out - source_in))
print(string.format("  ✓ audio duration = %d samples (10s × %dHz)",
    source_out - source_in, EXPECTED_SR))

-- ─────────────────────────────────────────────────────────────────────
-- NSF: A/V media with audio channels but no recorded sample rate AND no
-- project default rate to fall back on is unresolvable. It must surface
-- as a loud assert, not silently resolve to 48000. (When a project
-- default IS supplied — the offline-import case below — the master builds
-- at that default instead of failing.)
-- ─────────────────────────────────────────────────────────────────────

local media_av_no_rate = Media.create({
    id = "media_av_no_rate",
    project_id = "proj1",
    name = "AVNoRate",
    file_path = "synthetic://av_no_rate.mov",
    duration_frames = 100,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 0,  -- the bug case: channels say "has audio", rate missing
    codec = "prores",
    metadata = dkjson.encode({
        start_tc_value = 0, start_tc_rate = 25,
    }),
})
media_av_no_rate:save(db)
local ok, err = pcall(Sequence.ensure_master, "media_av_no_rate", "proj1")
assert(not ok, "ensure_masterclip must fail when A/V media has no audio_sample_rate")
assert(tostring(err):match("no sample rate") or tostring(err):match("audio_sample_rate"),
    "assert message should identify the missing sample rate, got: " .. tostring(err))
print("  ✓ A/V media with zero audio_sample_rate fails loud (not silent 48000 fallback)")

-- ─────────────────────────────────────────────────────────────────────
-- Offline import: a clip whose project file gave audio_channels but no
-- sample rate (the file isn't on disk to probe — importers must not
-- probe) must still get an audio master dimension, built at the PROJECT
-- default rate. Domain: you can't compute audio sample positions without
-- a rate; the project's declared default stands in until relink probes
-- the real file and replaces it. ensure_master receives the default via
-- opts.sample_rate (the importer forwards project_settings.audio_sample_rate).
-- ─────────────────────────────────────────────────────────────────────
local PROJECT_DEFAULT_SR = 48000

local media_offline = Media.create({
    id = "media_offline_av",
    project_id = "proj1",
    name = "OfflineAV",
    file_path = "synthetic://offline_av.mov",
    duration_frames = 250,          -- 10 seconds @ 25fps
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 0,          -- offline: rate not yet known
    codec = "prores",
    metadata = dkjson.encode({ start_tc_value = 0, start_tc_rate = 25 }),
})
assert(media_offline:save(), "Failed to save offline media")

local off_id = Sequence.ensure_master("media_offline_av", "proj1",
    { sample_rate = PROJECT_DEFAULT_SR })
assert(off_id, "ensure_master must succeed for offline media given a project default rate")

local off_stmt = assert(db:prepare([[
    SELECT mr.audio_sample_rate, mr.source_in_frame, mr.source_out_frame
    FROM media_refs mr
    JOIN tracks t ON mr.track_id = t.id
    WHERE mr.owner_sequence_id = ? AND t.track_type = 'AUDIO'
    ORDER BY t.track_index
    LIMIT 1
]]))
off_stmt:bind_value(1, off_id)
assert(off_stmt:exec() and off_stmt:next(), "offline master has no audio media_ref")
local off_rate = off_stmt:value(0)
local off_in   = off_stmt:value(1)
local off_out  = off_stmt:value(2)
off_stmt:finalize()

assert(off_rate == PROJECT_DEFAULT_SR, string.format(
    "offline audio media_ref must carry the project default rate %d, got %s",
    PROJECT_DEFAULT_SR, tostring(off_rate)))
-- 10 seconds × 48000 Hz = 480,000 samples.
assert((off_out - off_in) == 480000, string.format(
    "offline audio duration must be 10s × 48000 = 480000 samples, got %d",
    off_out - off_in))
print(string.format("  ✓ offline media adopts project default rate %d (480000 samples)",
    off_rate))

-- ─────────────────────────────────────────────────────────────────────
-- Precedence: a media whose OWN sample rate is known keeps it even when a
-- project default is offered. The default is a fallback for unknown rates,
-- never an override of a real one — otherwise a 96kHz field recording
-- would be silently re-clocked to the project's 48kHz default.
-- ─────────────────────────────────────────────────────────────────────
local media_known = Media.create({
    id = "media_known_96k",
    project_id = "proj1",
    name = "Known96k",
    file_path = "synthetic://known_96k.mov",
    duration_frames = 250,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 96000,      -- real, known rate
    codec = "prores",
    metadata = dkjson.encode({
        start_tc_value = 0, start_tc_rate = 25,
        start_tc_audio_samples = 0, start_tc_audio_rate = 96000,
    }),
})
assert(media_known:save(), "Failed to save known-rate media")

local kn_id = Sequence.ensure_master("media_known_96k", "proj1",
    { sample_rate = PROJECT_DEFAULT_SR })   -- offer a DIFFERENT default
local kn_stmt = assert(db:prepare([[
    SELECT mr.audio_sample_rate
    FROM media_refs mr
    JOIN tracks t ON mr.track_id = t.id
    WHERE mr.owner_sequence_id = ? AND t.track_type = 'AUDIO'
    ORDER BY t.track_index
    LIMIT 1
]]))
kn_stmt:bind_value(1, kn_id)
assert(kn_stmt:exec() and kn_stmt:next(), "known-rate master has no audio media_ref")
local kn_rate = kn_stmt:value(0)
kn_stmt:finalize()
assert(kn_rate == 96000, string.format(
    "known media rate (96000) must win over the project default (%d), got %s",
    PROJECT_DEFAULT_SR, tostring(kn_rate)))
print("  ✓ known media rate wins over project default (no override)")

print("\n✅ test_ensure_masterclip_uses_media_audio_rate.lua passed")
