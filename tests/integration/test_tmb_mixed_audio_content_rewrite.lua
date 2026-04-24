-- Integration test: the MIXED-audio path (what PlaybackController
-- actually pulls from during playback) must also invalidate on
-- media_content_changed. TMB_GET_MIXED_AUDIO reads m_mixed_cache
-- first; if that isn't cleared on InvalidatePath, the sound card
-- keeps receiving PCM from the old file bytes after a swap.
--
-- This complements test_tmb_audio_content_rewrite_invalidation (which
-- exercises GetTrackAudio). The mix cache is an additional tier
-- built on top of GetTrackAudio — different cache, different
-- invariant, distinct test.
--
-- Runs via: ./build/bin/JVEEditor --test tests/integration/test_tmb_mixed_audio_content_rewrite.lua

local ienv = require("integration.integration_test_env")
local EMP  = ienv.require_emp()
local Signals = require("core.signals")
local ffi = require("ffi")

print("=== test_tmb_mixed_audio_content_rewrite.lua ===")

local SRC_A = ienv.test_media_path("test_tone_48k_stereo.wav")
local SRC_B = ienv.test_media_path("test_click_48k_stereo.wav")
local SWAP = "/tmp/jve/tmb_mixed_swap_" .. os.time() .. ".wav"
os.execute("mkdir -p /tmp/jve")

local function copy_file(src, dst)
    assert(os.execute(string.format("cp %q %q", src, dst)), "cp failed")
end

local function hash_pcm(pcm)
    local info = EMP.PCM_INFO(pcm)
    assert(info and info.frames, "PCM_INFO missing")
    local ptr = EMP.PCM_DATA_PTR(pcm)
    local bytes = ffi.cast("const uint8_t*", ptr)
    local n = math.min(4096, info.frames * info.channels * 4)
    local h = 2166136261ULL
    for i = 0, n - 1 do
        h = bit.bxor(h, bytes[i])
        h = h * 16777619ULL
    end
    return tostring(h), info
end

copy_file(SRC_A, SWAP)
local probe = EMP.MEDIA_FILE_PROBE(SWAP)
assert(probe and probe.has_audio, "probe failed (no audio)")
local rate_num  = probe.fps_numerator or 24
local rate_den  = probe.fps_denominator or 1

local clip = {
    clip_id = "mix_clip", media_path = SWAP,
    timeline_start = 0, duration = 20,
    source_in = probe.first_frame_tc or 0,
    rate_num = rate_num, rate_den = rate_den, speed_ratio = 1.0, volume = 1.0,
}

local SR, CH = 48000, 2
local T0_US, T1_US = 100000, 350000

local tmb = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb, rate_num, rate_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CH)
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { clip })
EMP.TMB_SET_AUDIO_MIX_PARAMS(tmb, { { track_index = 1, volume = 1.0 } }, SR, CH)

local listener = Signals.connect("media_content_changed", function(p)
    EMP.TMB_INVALIDATE_PATH(tmb, p)
end, 20)

-- Stage A: pull mixed audio — goes through GetMixedAudio → (cache miss
-- → sync execute_mix_range → GetTrackAudio → decode). First call also
-- seeds audio_cache.
local pcm_a = EMP.TMB_GET_MIXED_AUDIO(tmb, T0_US, T1_US)
assert(pcm_a, "stage A: mixed audio returned nil")
local hash_a = hash_pcm(pcm_a)
print(string.format("  stage A mixed: hash=%s", hash_a))

-- Stage B: swap the underlying file, invalidate, pull again.
copy_file(SRC_B, SWAP)
Signals.emit("media_content_changed", SWAP)

local pcm_b = EMP.TMB_GET_MIXED_AUDIO(tmb, T0_US, T1_US)
assert(pcm_b, "stage B: mixed audio returned nil")
local hash_b = hash_pcm(pcm_b)
print(string.format("  stage B mixed: hash=%s", hash_b))

assert(hash_a ~= hash_b, string.format(
    "TMB_GET_MIXED_AUDIO served stale PCM after media_content_changed "
    .. "(hash_a=%s hash_b=%s) — mix cache / audio cache invalidation regressed",
    hash_a, hash_b))

Signals.disconnect(listener)
EMP.TMB_RELEASE_ALL(tmb)
EMP.TMB_CLOSE(tmb)
os.remove(SWAP)

print("✅ test_tmb_mixed_audio_content_rewrite.lua passed")
os.exit(0)
