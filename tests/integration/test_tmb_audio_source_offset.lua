-- Integration test: TMB decodes audio from correct source position.
--
-- Verifies that source_in offsets produce different PCM output.
-- Uses countdown_chirp_30s.mp4 (25fps, 48kHz mono, 30s) which has
-- time-varying audio content — different source_in positions MUST
-- produce different samples.
--
-- This test exercises the core source_in→seek path in GetTrackAudio.
-- A broken source_in conversion (e.g., not converting frames→us, or
-- ignoring source_in entirely) would cause both offsets to return
-- identical audio.

local ienv = require("integration.integration_test_env")
local ffi = require("ffi")

print("=== test_tmb_audio_source_offset.lua ===")

local EMP = ienv.require_emp()
local media_path = ienv.test_media_path("countdown_chirp_30s.mp4")

local SR = 48000
local CHANNELS = 1
local FPS_NUM = 25
local FPS_DEN = 1

-- Helper: compute RMS energy of a PCM chunk
ffi.cdef[[
    // Already declared if needed
]]
local function pcm_rms(pcm)
    local info = EMP.PCM_INFO(pcm)
    if info.frames == 0 then return 0 end
    local ptr = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))
    local sum = 0
    local n = info.frames * info.channels
    for i = 0, n - 1 do
        local s = ptr[i]
        sum = sum + s * s
    end
    return math.sqrt(sum / n)
end

-- Helper: get first N samples as a table for comparison
local function pcm_first_samples(pcm, count)
    local info = EMP.PCM_INFO(pcm)
    local ptr = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))
    local n = math.min(count, info.frames * info.channels)
    local samples = {}
    for i = 0, n - 1 do
        samples[i + 1] = tonumber(ptr[i])
    end
    return samples
end

-- ═══════════════════════════════════════════════════════════════
-- 1. Two clips from same media, different source_in, must produce
--    different audio
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1: Different source_in → different audio ---")

-- Clip A: source_in=0 (start of file)
-- Clip B: source_in=250 (10 seconds in at 25fps)
-- Both at timeline_start=0 but on different TMBs to isolate
local SOURCE_IN_A = 0
local SOURCE_IN_B = 250  -- 10 seconds into 30-second file

local function decode_audio_at(source_in, label)
    local tmb = EMP.TMB_CREATE(0)  -- sync decode
    EMP.TMB_SET_SEQUENCE_RATE(tmb, FPS_NUM, FPS_DEN)
    EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CHANNELS)

    local clip = {
        clip_id = "clip-" .. label,
        media_path = media_path,
        timeline_start = 0,
        duration = 100,       -- 4 seconds of timeline
        source_in = source_in,
        rate_num = FPS_NUM,
        rate_den = FPS_DEN,
        speed_ratio = 1.0,
    }
    EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { clip })

    -- Decode 0.5 seconds of audio starting at timeline frame 0
    -- t0/t1 are in microseconds
    local t0_us = 0
    local t1_us = 500000  -- 0.5s

    local pcm = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, t0_us, t1_us, SR, CHANNELS)
    EMP.TMB_CLOSE(tmb)
    return pcm
end

local pcm_a = decode_audio_at(SOURCE_IN_A, "A")
local pcm_b = decode_audio_at(SOURCE_IN_B, "B")

assert(pcm_a, "source_in=0 returned nil PCM")
assert(pcm_b, "source_in=250 returned nil PCM")

local info_a = EMP.PCM_INFO(pcm_a)
local info_b = EMP.PCM_INFO(pcm_b)

assert(info_a.frames > 0, "source_in=0: empty PCM")
assert(info_b.frames > 0, "source_in=250: empty PCM")

-- Compare first 64 samples — must differ
local samples_a = pcm_first_samples(pcm_a, 64)
local samples_b = pcm_first_samples(pcm_b, 64)

local identical_count = 0
for i = 1, math.min(#samples_a, #samples_b) do
    if math.abs(samples_a[i] - samples_b[i]) < 1e-6 then
        identical_count = identical_count + 1
    end
end

-- With 10 seconds of offset in a chirp file, nearly all samples should differ
assert(identical_count < #samples_a * 0.5,
    string.format("source_in=0 vs 250: %d/%d samples identical — source_in not applied",
        identical_count, #samples_a))

local rms_a = pcm_rms(pcm_a)
local rms_b = pcm_rms(pcm_b)
print(string.format("  PASS: src_in=0 RMS=%.4f, src_in=250 RMS=%.4f, %d/%d samples differ",
    rms_a, rms_b, #samples_a - identical_count, #samples_a))

-- ═══════════════════════════════════════════════════════════════
-- 2. source_in=0 produces non-silent audio (decode actually works)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2: Audio decode produces non-silent output ---")

assert(rms_a > 0.001, string.format("source_in=0 RMS=%.6f — silent (decode failed?)", rms_a))
assert(rms_b > 0.001, string.format("source_in=250 RMS=%.6f — silent (decode failed?)", rms_b))
print(string.format("  PASS: both clips produce audible content (RMS > 0.001)"))

-- ═══════════════════════════════════════════════════════════════
-- 3. Large source_in offset produces audio from correct position
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3: source_in=500 (20s offset) still works ---")

local pcm_c = decode_audio_at(500, "C")  -- 20 seconds in
assert(pcm_c, "source_in=500 returned nil")
local info_c = EMP.PCM_INFO(pcm_c)
assert(info_c.frames > 0, "source_in=500: empty PCM")
local rms_c = pcm_rms(pcm_c)
assert(rms_c > 0.001, string.format("source_in=500 RMS=%.6f — silent", rms_c))

-- Must also differ from source_in=0 AND source_in=250
local samples_c = pcm_first_samples(pcm_c, 64)
local match_a, match_b = 0, 0
for i = 1, math.min(#samples_a, #samples_c) do
    if math.abs(samples_a[i] - samples_c[i]) < 1e-6 then match_a = match_a + 1 end
    if math.abs(samples_b[i] - samples_c[i]) < 1e-6 then match_b = match_b + 1 end
end
assert(match_a < #samples_a * 0.5,
    string.format("src_in=500 vs 0: %d/%d identical", match_a, #samples_a))
assert(match_b < #samples_b * 0.5,
    string.format("src_in=500 vs 250: %d/%d identical", match_b, #samples_b))

print(string.format("  PASS: source_in=500 distinct from 0 and 250 (RMS=%.4f)", rms_c))

-- ═══════════════════════════════════════════════════════════════
-- 4. Audio with non-unity speed_ratio
-- ═══════════════════════════════════════════════════════════════
print("\n--- 4: Non-unity speed_ratio (0.5x) ---")

local function decode_audio_speed(source_in, speed, label)
    local tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, FPS_NUM, FPS_DEN)
    EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CHANNELS)

    local clip = {
        clip_id = "clip-speed-" .. label,
        media_path = media_path,
        timeline_start = 0,
        duration = 200,
        source_in = source_in,
        rate_num = FPS_NUM,
        rate_den = FPS_DEN,
        speed_ratio = speed,
    }
    EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { clip })

    local pcm = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, 0, 500000, SR, CHANNELS)
    EMP.TMB_CLOSE(tmb)
    return pcm
end

local pcm_1x = decode_audio_speed(100, 1.0, "1x")
local pcm_half = decode_audio_speed(100, 0.5, "half")
assert(pcm_1x and pcm_half, "speed test: nil PCM")

local info_1x = EMP.PCM_INFO(pcm_1x)  -- luacheck: no unused
local info_half = EMP.PCM_INFO(pcm_half)  -- luacheck: no unused
-- At 0.5x speed, same timeline duration covers half the source material
-- so the decoded audio should differ
local s1x = pcm_first_samples(pcm_1x, 64)
local shalf = pcm_first_samples(pcm_half, 64)
local speed_match = 0
for i = 1, math.min(#s1x, #shalf) do
    if math.abs(s1x[i] - shalf[i]) < 1e-6 then speed_match = speed_match + 1 end
end
assert(speed_match < #s1x * 0.8,
    string.format("1x vs 0.5x: %d/%d identical — speed_ratio ignored?", speed_match, #s1x))
print(string.format("  PASS: 1x vs 0.5x differ (%d/%d samples match)", speed_match, #s1x))

-- ═══════════════════════════════════════════════════════════════
-- 5. Two clips at different timeline positions, same source region
-- ═══════════════════════════════════════════════════════════════
print("\n--- 5: Same source, different timeline position ---")

local tmb = EMP.TMB_CREATE(0)
EMP.TMB_SET_SEQUENCE_RATE(tmb, FPS_NUM, FPS_DEN)
EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CHANNELS)

-- Clip at timeline 0-100 from source 50
-- Clip at timeline 200-300 from source 50 (same source region!)
local clips = {
    { clip_id = "pos-A", media_path = media_path,
      timeline_start = 0, duration = 100, source_in = 50,
      rate_num = FPS_NUM, rate_den = FPS_DEN, speed_ratio = 1.0 },
    { clip_id = "pos-B", media_path = media_path,
      timeline_start = 200, duration = 100, source_in = 50,
      rate_num = FPS_NUM, rate_den = FPS_DEN, speed_ratio = 1.0 },
}
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, clips)

-- Decode from clip A's region (timeline 0..0.5s)
local pcm_pos_a = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, 0, 500000, SR, CHANNELS)
-- Decode from clip B's region (timeline 8..8.5s = 200 frames at 25fps)
local pcm_pos_b = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, 8000000, 8500000, SR, CHANNELS)
EMP.TMB_CLOSE(tmb)

assert(pcm_pos_a and pcm_pos_b, "position test: nil PCM")
local spa = pcm_first_samples(pcm_pos_a, 64)
local spb = pcm_first_samples(pcm_pos_b, 64)

-- Same source region → should produce identical audio content
local pos_match = 0
for i = 1, math.min(#spa, #spb) do
    if math.abs(spa[i] - spb[i]) < 1e-4 then pos_match = pos_match + 1 end
end
-- Allow some tolerance for AAC codec jitter
assert(pos_match > #spa * 0.7,
    string.format("same source at different tl positions: only %d/%d match",
        pos_match, #spa))
print(string.format("  PASS: same source_in=50 at tl=0 and tl=200: %d/%d samples match",
    pos_match, #spa))

print("\n✅ test_tmb_audio_source_offset.lua passed")
