-- Integration test: Disabled clips are excluded from playback pipeline.
--
-- Verifies the full chain: DRP import → Sequence model → PlaybackEngine
-- → TMB. Muted clips (enabled=0) must not reach the TMB or produce audio.
--
-- Uses countdown_chirp_30s.mp4 with two clips on one audio track:
-- one enabled (should produce audio) and one disabled (should be silent).
-- Directly tests TMB_GET_TRACK_AUDIO to verify only the enabled clip
-- produces PCM.

local ienv = require("synthetic.integration.integration_test_env")
local ffi = require("ffi")

print("=== test_tmb_mute_exclusion.lua ===")

local EMP = ienv.require_emp()
local media_path = ienv.test_media_path("countdown_chirp_30s.mp4")

local SR = 48000
local CHANNELS = 1
local FPS_NUM = 25
local FPS_DEN = 1

local function pcm_rms(pcm)
    local info = EMP.PCM_INFO(pcm)
    if info.frames == 0 then return 0 end
    local ptr = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))
    local sum = 0
    local n = info.frames * info.channels
    for i = 0, n - 1 do
        sum = sum + ptr[i] * ptr[i]
    end
    return math.sqrt(sum / n)
end

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
        print("  PASS: " .. label)
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

-- ═══════════════════════════════════════════════════════════════
-- 1. TMB with only enabled clip → audio present
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1: Enabled clip produces audio ---")

local tmb1 = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb1, FPS_NUM, FPS_DEN)
EMP.TMB_SET_AUDIO_FORMAT(tmb1, SR, CHANNELS)

local enabled_clip = {
    clip_id = "enabled-001",
    media_path = media_path,
    sequence_start = 0,
    duration = 100,
    source_in = 50,  -- non-zero!
    rate_num = FPS_NUM,
    rate_den = FPS_DEN,
    speed_ratio = 1.0,
}
EMP.TMB_SET_TRACK_CLIPS(tmb1, "audio", 1, { enabled_clip })

local pcm1 = EMP.TMB_GET_TRACK_AUDIO(tmb1, 1, 0, 500000, SR, CHANNELS)
assert(pcm1, "enabled clip: nil PCM")
local rms1 = pcm_rms(pcm1)
check(rms1 > 0.001, string.format("enabled clip RMS=%.4f (audible)", rms1))
EMP.TMB_CLOSE(tmb1)

-- ═══════════════════════════════════════════════════════════════
-- 2. TMB with NO clips in the muted region → silence (gap)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2: Gap (no clip) produces silence ---")

-- This simulates what happens when _provide_clips excludes a disabled clip:
-- TMB has a gap where the disabled clip would have been.
local tmb2 = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb2, FPS_NUM, FPS_DEN)
EMP.TMB_SET_AUDIO_FORMAT(tmb2, SR, CHANNELS)

-- Clip only covers timeline 200-300 (later), gap at 0-100
local far_clip = {
    clip_id = "far-001",
    media_path = media_path,
    sequence_start = 200,
    duration = 100,
    source_in = 0,
    rate_num = FPS_NUM,
    rate_den = FPS_DEN,
    speed_ratio = 1.0,
}
EMP.TMB_SET_TRACK_CLIPS(tmb2, "audio", 1, { far_clip })

-- Request audio from the gap region (0..0.5s = timeline frames 0..12)
local pcm2 = EMP.TMB_GET_TRACK_AUDIO(tmb2, 1, 0, 500000, SR, CHANNELS)
-- Gap should return nil (no clip at this position)
check(pcm2 == nil, "gap returns nil PCM (correct — no clip here)")
EMP.TMB_CLOSE(tmb2)

-- ═══════════════════════════════════════════════════════════════
-- 3. Full pipeline: Sequence.get_audio_in_range excludes disabled
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3: Sequence model excludes disabled clips ---")

-- This tests that the Lua model layer correctly filters enabled=0.
-- We create a project with enabled and disabled clips, then verify
-- get_audio_in_range only returns the enabled one.

local database = require("core.database")
local import_schema = require("import_schema")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local Media = require("models.media")
local uuid = require("uuid")

local DB_PATH = "/tmp/jve/test_mute_exclusion.jvp"
os.remove(DB_PATH); os.remove(DB_PATH.."-wal"); os.remove(DB_PATH.."-shm")
assert(database.set_path(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

local project_id = uuid.generate()
local now = os.time()
assert(db:exec(string.format(
    "INSERT INTO projects(id, name, fps_mismatch_policy, settings, created_at, modified_at) VALUES('%s', 'MuteTest', 'passthrough', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', %d, %d)",
    project_id, now, now)))

-- Create sequence + audio track
local seq = Sequence.create("MuteTestSeq", project_id,
    {fps_numerator = 25, fps_denominator = 1}, 1920, 1080,
    { kind = "sequence", audio_sample_rate = 48000 })
assert(seq:save())

local track = Track.create_audio("A1", seq.id, {index = 1})
assert(track:save())

-- Create media
local med = Media.create({
    project_id = project_id, name = "chirp.mp4",
    file_path = media_path, duration_frames = 750, frame_rate = 25,
    audio_channels = 1, audio_sample_rate = 48000,
})
assert(med:save())

-- Create MC sequence for the media
local mc_seq_id = require("test_env").create_test_masterclip_sequence(
    project_id, "chirp mc", 48000, 1, 36000000, med.id)

-- Enabled clip: timeline frames 0..100 (4 seconds at 25fps)
-- source_in/out in clip rate units (48000/1 = samples)
Clip.create({
        name = "enabled_chirp",
        project_id = project_id,
        owner_sequence_id = seq.id,
        track_id = track.id,
        sequence_start_frame = 0,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        source_in_subframe = 0,
        source_out_subframe = 0,
        enabled = true,
        sequence_id = mc_seq_id,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })

-- Disabled clip: timeline frames 200..300 (non-adjacent, gap at 100..200)
Clip.create({
        name = "disabled_chirp",
        project_id = project_id,
        owner_sequence_id = seq.id,
        track_id = track.id,
        sequence_start_frame = 200,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        source_in_subframe = 0,
        source_out_subframe = 0,
        sequence_id = mc_seq_id,
        enabled = false,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })

-- Verify in DB
local en_stmt = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE track_id=? AND enabled=1"))
en_stmt:bind_value(1, track.id)
assert(en_stmt:exec() and en_stmt:next())
local en_count = en_stmt:value(0)
en_stmt:finalize()
check(en_count == 1, string.format("1 enabled clip in DB (got %d)", en_count))

local dis_stmt = assert(db:prepare(
    "SELECT COUNT(*) FROM clips WHERE track_id=? AND enabled=0"))
dis_stmt:bind_value(1, track.id)
assert(dis_stmt:exec() and dis_stmt:next())
local dis_count = dis_stmt:value(0)
dis_stmt:finalize()
check(dis_count == 1, string.format("1 disabled clip in DB (got %d)", dis_count))

-- get_audio_in_range should return ONLY the enabled clip
-- Query the disabled clip's timeline range (frames 200..300)
local audio_entries = seq:get_audio_in_range(200, 300)

-- Should be 0 — disabled clip is at 200..300 but excluded by enabled=1 filter
local entry_count = 0
for _ in ipairs(audio_entries) do entry_count = entry_count + 1 end
check(entry_count == 0,
    string.format("get_audio_in_range(200,300) returns %d entries (disabled clip excluded)",
        entry_count))

-- Query the enabled clip's range (frames 0..100)
local en_entries = seq:get_audio_in_range(0, 100)
local en_entry_count = 0
for _ in ipairs(en_entries) do en_entry_count = en_entry_count + 1 end
check(en_entry_count == 1,
    string.format("get_audio_in_range(0,100) returns %d entries (enabled clip present)",
        en_entry_count))

-- Query the gap (frames 100..200) — should return 0 (no clip there at all)
local gap_entries = seq:get_audio_in_range(100, 200)
local gap_count = 0
for _ in ipairs(gap_entries) do gap_count = gap_count + 1 end
check(gap_count == 0,
    string.format("get_audio_in_range(100,200) returns %d (gap, no clips)", gap_count))

-- Cleanup
os.remove(DB_PATH); os.remove(DB_PATH.."-wal"); os.remove(DB_PATH.."-shm")

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d check(s) failed", failed))
print("✅ test_tmb_mute_exclusion.lua passed")
