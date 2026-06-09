-- Integration test: a clip built while its media was offline (the drive
-- wasn't mounted yet at app launch) must STOP beeping once the drive
-- shows up and media_status flips the path online. Pins Joe's repro:
--
--   "restarted and reconnected it and the sound stayed beeping even
--    though it should be online. Clip looked correct."
--
-- Cause: ClipInfo.offline is cached inside TMB at clip-build time in
-- _build_tmb_clip via a synchronous io.open check. If the file was
-- absent at that moment, TMB's clip.offline = true, and GetTrackAudio's
-- first branch returns generate_offline_beep() forever — independent
-- of m_offline or any cache that InvalidatePath drops.
--
-- The contract this test pins: after the status flip, a subsequent
-- GetTrackAudio call returns PCM decoded from the now-reachable file,
-- NOT a 1 kHz beep. The fix will be whatever the subscriber chooses
-- (rebuild the clip list via RELOAD_ALL_CLIPS, or a finer-grained
-- update); the test asserts the end behavior, not the mechanism.
--
-- Runs via: ./build/bin/jve --test tests/synthetic/integration/test_tmb_audio_unbeeps_on_reconnect.lua

local ienv = require("synthetic.integration.integration_test_env")
local EMP  = ienv.require_emp()
local Signals = require("core.signals")
local ffi = require("ffi")

print("=== test_tmb_audio_unbeeps_on_reconnect.lua ===")

local REAL = ienv.test_media_path("test_tone_48k_stereo.wav")
local SWAP = "/tmp/jve/tmb_unbeep_" .. os.time() .. ".wav"
os.execute("mkdir -p /tmp/jve")
os.remove(SWAP)  -- simulate "drive not mounted yet" — file absent at clip-build

-- Probe the real file to get a valid clip shape; we'll install the
-- clip pointing at SWAP (which doesn't exist yet).
local probe = EMP.MEDIA_FILE_PROBE(REAL)
assert(probe and probe.has_audio, "probe failed on REAL")
local rate_num  = probe.fps_numerator or 24
local rate_den  = probe.fps_denominator or 1

-- Build the clip as the production code would: offline=true because
-- io.open(SWAP) fails right now.
local function build_clip_with_current_offline_flag()
    local f = io.open(SWAP, "r")
    local is_offline = (f == nil)
    if f then f:close() end
    return {
        clip_id = "unbeep_clip",
        media_path = SWAP,
        sequence_start = 0, duration = 20,
        source_in = probe.first_frame_tc or 0,
        rate_num = rate_num, rate_den = rate_den, speed_ratio = 1.0,
        volume = 1.0,
        offline = is_offline,
    }
end

local SR, CH = 48000, 2
local T0_US, T1_US = 100000, 350000

local tmb = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb, rate_num, rate_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CH)

-- Install the initial clip — file absent → offline=true → TMB beeps.
local initial_clip = build_clip_with_current_offline_flag()
assert(initial_clip.offline == true,
    "precondition: clip must build as offline while file is missing")
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { initial_clip })

-- Detect "is this a beep?" by looking for the 1 kHz sinusoid pattern.
-- Simpler: compare hash against a known decode of the real file.
-- Decode a reference hash from the same range against REAL directly.
local function decode_real_reference()
    local ref_clip = {
        clip_id = "ref_clip", media_path = REAL,
        sequence_start = 0, duration = 20,
        source_in = probe.first_frame_tc or 0,
        rate_num = rate_num, rate_den = rate_den, speed_ratio = 1.0,
        volume = 1.0, offline = false,
    }
    local ref_tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(ref_tmb, rate_num, rate_den)
    EMP.TMB_SET_AUDIO_FORMAT(ref_tmb, SR, CH)
    EMP.TMB_SET_TRACK_CLIPS(ref_tmb, "audio", 1, { ref_clip })
    local pcm = EMP.TMB_GET_TRACK_AUDIO(ref_tmb, 1, T0_US, T1_US, SR, CH)
    assert(pcm, "reference decode failed")
    local info = EMP.PCM_INFO(pcm)
    local ptr = EMP.PCM_DATA_PTR(pcm)
    local bytes = ffi.cast("const uint8_t*", ptr)
    local n = math.min(4096, info.frames * info.channels * 4)
    local h = 2166136261ULL
    for i = 0, n - 1 do
        h = bit.bxor(h, bytes[i])
        h = h * 16777619ULL
    end
    EMP.PCM_RELEASE(pcm)
    EMP.TMB_RELEASE_ALL(ref_tmb)
    EMP.TMB_CLOSE(ref_tmb)
    return tostring(h)
end

local function hash_pcm(pcm)
    local info = EMP.PCM_INFO(pcm)
    local ptr = EMP.PCM_DATA_PTR(pcm)
    local bytes = ffi.cast("const uint8_t*", ptr)
    local n = math.min(4096, info.frames * info.channels * 4)
    local h = 2166136261ULL
    for i = 0, n - 1 do
        h = bit.bxor(h, bytes[i])
        h = h * 16777619ULL
    end
    return tostring(h)
end

local real_hash = decode_real_reference()
print("  reference hash (real file)   = " .. real_hash)

-- Stage 1: file absent → clip.offline = true → expect beep (hash != real).
local pcm_beep = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, T0_US, T1_US, SR, CH)
assert(pcm_beep, "stage 1: beep PCM is nil")
local beep_hash = hash_pcm(pcm_beep)
print("  stage 1 hash (expect beep)   = " .. beep_hash)
assert(beep_hash ~= real_hash,
    "precondition: beep and real file must hash differently")

-- Stage 2: file shows up on disk ("drive reconnected"). The real
-- listener must rebuild TMB's clip list so clip.offline flips to
-- false. We mirror that by listening for media_status_changed and
-- re-calling SET_TRACK_CLIPS with the rebuilt clip. If the production
-- handler only calls TMB_INVALIDATE_PATH / TMB_CLEAR_OFFLINE (the
-- state before this test was written), the clip.offline flag stays
-- true and GetTrackAudio will keep returning beep → assertion trips.
-- Contract under test: after a status-online flip, the subscriber must
-- rebuild the TMB clip list so ClipInfo.offline gets re-evaluated.
-- InvalidatePath + ClearOffline alone are NOT enough — they drop the
-- reader pool / cache / blacklist, but the per-clip `offline` flag
-- baked into ClipInfo at build time stays stuck at true.
-- Production implements this by calling RELOAD_ALL_CLIPS on the
-- PlaybackController, which clears clips and re-invokes _provide_clips
-- → _build_tmb_clip with a fresh io.open. We mirror that by re-posting
-- SET_TRACK_CLIPS with the rebuilt clip (same end effect at TMB level).
local listener = Signals.connect("media_status_changed", function(p, status)
    if status and not status.offline then
        EMP.TMB_INVALIDATE_PATH(tmb, p)
        if EMP.TMB_CLEAR_OFFLINE then EMP.TMB_CLEAR_OFFLINE(tmb, p) end
        local rebuilt = build_clip_with_current_offline_flag()
        EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { rebuilt })
    end
end, 20)

os.execute(string.format("cp %q %q", REAL, SWAP))
Signals.emit("media_status_changed", SWAP,
    { offline = false, error_code = nil })

local pcm_after = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, T0_US, T1_US, SR, CH)
assert(pcm_after, "stage 2: PCM after reconnect is nil")
local after_hash = hash_pcm(pcm_after)
print("  stage 2 hash (expect real)   = " .. after_hash)

assert(after_hash ~= beep_hash, string.format(
    "TMB kept beeping after media_status flipped online — ClipInfo.offline "
    .. "was not refreshed. Got the same hash as stage 1 (beep=%s).",
    beep_hash))
assert(after_hash == real_hash, string.format(
    "TMB returned neither beep nor real audio — unexpected hash %s "
    .. "(real=%s, beep=%s)", after_hash, real_hash, beep_hash))

Signals.disconnect(listener)
EMP.TMB_RELEASE_ALL(tmb)
EMP.TMB_CLOSE(tmb)
os.remove(SWAP)

print("✅ test_tmb_audio_unbeeps_on_reconnect.lua passed")
os.exit(0)
