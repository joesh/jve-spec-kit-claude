-- SLOW_TEST
-- Integration test: TMB subtracts first_sample_tc from absolute TC source_in.
--
-- Verifies that source_in (absolute TC in samples) is correctly mapped to
-- file-relative position by subtracting the file's first_sample_tc
-- (from BWF time_reference or stream start_time).
--
-- When source_in = first_sample_tc + N, TMB should decode from file position N.
-- When source_in = first_sample_tc (no offset), TMB decodes from file start.
--
-- Requires a BWF WAV file (Anamnesis Stereo Mix). Skips gracefully if absent.

local ienv = require("synthetic.integration.integration_test_env")
local ffi = require("ffi")

print("=== test_tmb_bwf_offset.lua ===")

local EMP = ienv.require_emp()

-- BWF WAV path (external — from Anamnesis sound post)
local BWF_WAV = "/Users/joe/Local/Anamnesis/2026-02-28-mm/anamnesis joe edit/"
    .. "Volumes/AnamBack4 Joe/OUTPUT/From Sound Post/Ross Wilkes-Houghton Sound Mix/"
    .. "Anemnesis Stereo Mix - Online 23012026_01.wav"

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

if not file_exists(BWF_WAV) then
    print("SKIP: BWF WAV not found — requires Anamnesis media")
    print("✅ test_tmb_bwf_offset.lua skipped")
    os.exit(0)
end

-- Probe BWF metadata
local probe = EMP.MEDIA_FILE_PROBE(BWF_WAV)
assert(probe.bwf_time_reference >= 0,
    "WAV missing BWF time_reference — not a Broadcast Wave file")
assert(probe.audio_sample_rate == 48000, "expected 48kHz")

-- first_sample_tc should equal bwf_time_reference for BWF files
assert(probe.first_sample_tc == probe.bwf_time_reference,
    string.format("first_sample_tc=%d should equal bwf_time_reference=%d",
        probe.first_sample_tc, probe.bwf_time_reference))

local bwf_samples = probe.bwf_time_reference
print(string.format("  BWF: first_sample_tc=%d samples = %.4fs (%s)",
    bwf_samples, bwf_samples / probe.audio_sample_rate,
    string.format("%02d:%02d:%02d",
        math.floor(bwf_samples / probe.audio_sample_rate / 3600),
        math.floor(bwf_samples / probe.audio_sample_rate / 60) % 60,
        math.floor(bwf_samples / probe.audio_sample_rate) % 60)))

local SR = 48000
local CHANNELS = 2
local FPS_NUM = 25
local FPS_DEN = 1

-- Helper: PCM RMS and first samples
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

-- Helper: decode audio with source_in as absolute TC (samples)
local function decode_with_source_in(source_in_samples, label)
    local tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, FPS_NUM, FPS_DEN)
    EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CHANNELS)

    local clip = {
        clip_id = "bwf-" .. label,
        media_path = BWF_WAV,
        sequence_start = 0,
        duration = 200,
        source_in = source_in_samples,
        rate_num = SR,    -- audio clip rate = sample rate
        rate_den = 1,
        speed_ratio = 1.0,
    }
    EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { clip })

    local pcm = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, 0, 500000, SR, CHANNELS)
    EMP.TMB_CLOSE(tmb)
    return pcm
end

-- ═══════════════════════════════════════════════════════════════
-- 1. source_in = first_sample_tc (file start — 0s into file)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1: source_in = first_sample_tc (file start) ---")

local pcm_at_start = decode_with_source_in(bwf_samples, "at-start")
assert(pcm_at_start, "decode at file start returned nil")
local rms_start = pcm_rms(pcm_at_start)
check(rms_start >= 0, string.format("file start RMS=%.4f", rms_start))

-- ═══════════════════════════════════════════════════════════════
-- 2. source_in = first_sample_tc + 30s (30s into file)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2: source_in = first_sample_tc + 30s ---")

local offset_30s = 30 * SR  -- 30 seconds in samples
local pcm_at_30s = decode_with_source_in(bwf_samples + offset_30s, "at-30s")
assert(pcm_at_30s, "decode at 30s returned nil")
local rms_30s = pcm_rms(pcm_at_30s)
check(rms_30s > 0.001, string.format("30s RMS=%.4f (non-silent)", rms_30s))

-- ═══════════════════════════════════════════════════════════════
-- 3. The two decodes MUST produce different audio
--    (proving first_sample_tc subtraction works)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3: Different source_in produces different audio ---")

local s_start = pcm_first_samples(pcm_at_start, 128)
local s_30s = pcm_first_samples(pcm_at_30s, 128)

local match_count = 0
for i = 1, math.min(#s_start, #s_30s) do
    if math.abs(s_start[i] - s_30s[i]) < 1e-6 then match_count = match_count + 1 end
end

check(match_count < #s_start * 0.5,
    string.format("start vs 30s: %d/%d identical (should differ)",
        match_count, #s_start))

-- ═══════════════════════════════════════════════════════════════
-- 4. Verify probe reports correct TC origin fields
-- ═══════════════════════════════════════════════════════════════
print("\n--- 4: Probe TC origin fields ---")

check(probe.first_frame_tc ~= nil, "probe.first_frame_tc exists")
check(probe.first_sample_tc ~= nil, "probe.first_sample_tc exists")
check(probe.first_sample_tc > 0,
    string.format("first_sample_tc=%d > 0 (BWF file)", probe.first_sample_tc))

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("FAILED: %d check(s)", failed))
print("✅ test_tmb_bwf_offset.lua passed")
