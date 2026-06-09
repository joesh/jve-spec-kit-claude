-- Integration test: sibling of test_tmb_content_rewrite_invalidation for
-- AUDIO. After `media_content_changed` fires for an in-place rewrite,
-- TMB must return PCM decoded from the NEW bytes, not stale samples
-- from audio_cache or the mixed-cache pre-mix.
--
-- Regression this pins: "sound still plays from stale file" — the
-- symptom Joe saw after the first invalidation landing. If audio_cache
-- / m_mixed_cache / the decoded PCM reader are NOT all dropped, the
-- pull path re-serves bytes from the pre-swap file even though
-- InvalidatePath fired.
--
-- Runs via: ./build/bin/jve --test tests/synthetic/integration/test_tmb_audio_content_rewrite_invalidation.lua

local ienv = require("synthetic.integration.integration_test_env")
local EMP  = ienv.require_emp()
local Signals = require("core.signals")
local ffi = require("ffi")

print("=== test_tmb_audio_content_rewrite_invalidation.lua ===")

-- Must have ACTUAL audio content — the .mp4 test clips have silent
-- audio tracks (peak -inf dB), so swapping their bytes wouldn't change
-- the decoded PCM. The WAV fixtures are 48k stereo PCM with non-zero
-- content (a sustained tone vs. a click) — decoded samples differ.
local SRC_A = ienv.test_media_path("test_tone_48k_stereo.wav")
local SRC_B = ienv.test_media_path("test_click_48k_stereo.wav")
local SWAP = "/tmp/jve/tmb_audio_swap_" .. os.time() .. ".wav"
os.execute("mkdir -p /tmp/jve")

local function copy_file(src, dst)
    local cmd = string.format("cp %q %q", src, dst)
    local rc = os.execute(cmd)
    assert(rc == 0 or rc == true, "cp failed: " .. cmd)
end

-- FNV-1a hash over the first N float samples of decoded PCM. Same
-- principle as the video test: two unrelated AAC sources produce
-- wildly different PCM, so a window is plenty to detect "same vs
-- different."
local function hash_pcm(pcm)
    local info = EMP.PCM_INFO(pcm)
    assert(info and info.frames and info.channels,
        "PCM_INFO missing fields")
    local ptr = EMP.PCM_DATA_PTR(pcm)
    assert(ptr, "PCM_DATA_PTR returned nil")
    local bytes = ffi.cast("const uint8_t*", ptr)
    -- Each sample is 4 bytes (F32). Hash first 4 KB (~256 stereo samples).
    local n = math.min(4096, info.frames * info.channels * 4)
    local h = 2166136261ULL
    for i = 0, n - 1 do
        h = bit.bxor(h, bytes[i])
        h = h * 16777619ULL
    end
    return tostring(h), info
end

-- ------------------------------------------------------------------
-- Stage A: SWAP = SRC_A. Build TMB + decode a PCM window.
-- ------------------------------------------------------------------
copy_file(SRC_A, SWAP)

local probe = EMP.MEDIA_FILE_PROBE(SWAP)
assert(probe and probe.has_audio, "probe failed (no audio) on SWAP stage A")
local rate_num  = probe.fps_numerator or 24
local rate_den  = probe.fps_denominator or 1
local tc_origin = probe.first_frame_tc or 0

local clip = {
    clip_id        = "audio_swap_clip",
    media_path     = SWAP,
    sequence_start = 0,
    duration       = 20,
    source_in      = tc_origin,
    rate_num       = rate_num,
    rate_den       = rate_den,
    speed_ratio    = 1.0,
    volume         = 1.0,
}

-- Pull a 250 ms window early in the clip (well within both fixtures).
local T0_US, T1_US = 100000, 350000

local TRACK = 1
local SR = 48000
local CH = 2

local tmb = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb, rate_num, rate_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CH)
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", TRACK, { clip })

-- Mirror the production contract: invalidate on media_content_changed.
local listener = Signals.connect("media_content_changed", function(p)
    EMP.TMB_INVALIDATE_PATH(tmb, p)
end, 20)

local pcm_a = EMP.TMB_GET_TRACK_AUDIO(tmb, TRACK, T0_US, T1_US, SR, CH)
assert(pcm_a, "stage A: TMB_GET_TRACK_AUDIO returned nil")
local hash_a, info_a = hash_pcm(pcm_a)
print(string.format("  stage A decoded audio [%d..%d]us: %d frames, hash=%s",
    T0_US, T1_US, info_a.frames, hash_a))


-- ------------------------------------------------------------------
-- Stage B: overwrite SWAP with SRC_B, emit the signal, pull the same
-- window again. Must return PCM from the new bytes.
-- ------------------------------------------------------------------
copy_file(SRC_B, SWAP)
Signals.emit("media_content_changed", SWAP)

local pcm_b = EMP.TMB_GET_TRACK_AUDIO(tmb, TRACK, T0_US, T1_US, SR, CH)
assert(pcm_b, "stage B: TMB_GET_TRACK_AUDIO returned nil")
local hash_b, info_b = hash_pcm(pcm_b)
print(string.format("  stage B decoded audio [%d..%d]us: %d frames, hash=%s",
    T0_US, T1_US, info_b.frames, hash_b))

assert(hash_a ~= hash_b, string.format(
    "TMB served stale PCM after content rewrite + media_content_changed "
    .. "(hash_a=%s hash_b=%s) — audio cache invalidation regressed",
    hash_a, hash_b))

Signals.disconnect(listener)
EMP.TMB_RELEASE_ALL(tmb)
EMP.TMB_CLOSE(tmb)
os.remove(SWAP)

print("✅ test_tmb_audio_content_rewrite_invalidation.lua passed")
os.exit(0)
