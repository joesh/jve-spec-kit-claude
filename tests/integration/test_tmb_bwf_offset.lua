-- SLOW_TEST
-- Integration test: TMB applies BWF offset to audio seek position.
--
-- TDD: This test verifies the BWF precompute feature. It WILL FAIL until
-- the bwf_offset_us field is implemented on ClipInfo and TMB adjusts
-- source_in at clip-add time.
--
-- The test constructs two TMB clips pointing to the same BWF WAV file:
-- one with media_start_tc_us=0 (no adjustment) and one with a non-zero
-- media_start_tc_us. If BWF offset is correctly applied, the adjusted
-- clip should seek to a different file position and produce different PCM.
--
-- Requires a BWF WAV file (Anamnesis Stereo Mix). Skips gracefully if absent.

local ienv = require("integration.integration_test_env")
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

local bwf_samples = probe.bwf_time_reference
print(string.format("  BWF: %d samples = %.4fs (%s)",
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

-- ═══════════════════════════════════════════════════════════════
-- 1. Clip WITHOUT media_start_tc_us (baseline — no BWF adjustment)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1: Baseline (no BWF adjustment) ---")

-- Precompute bwf_offset_us (same formula as PlaybackEngine._build_tmb_clip):
-- bwf_offset_us = BWF_time_reference_us - MediaStartTime_us
-- TMB subtracts this from source_in_us to get file-relative seek position.
local function decode_with_bwf_offset(bwf_offset, source_in, label)
    local tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, FPS_NUM, FPS_DEN)
    EMP.TMB_SET_AUDIO_FORMAT(tmb, SR, CHANNELS)

    local clip = {
        clip_id = "bwf-" .. label,
        media_path = BWF_WAV,
        timeline_start = 0,
        duration = 200,
        source_in = source_in,
        rate_num = FPS_NUM,
        rate_den = FPS_DEN,
        speed_ratio = 1.0,
        bwf_offset_us = bwf_offset,
    }
    EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { clip })

    local pcm = EMP.TMB_GET_TRACK_AUDIO(tmb, 1, 0, 500000, SR, CHANNELS)
    EMP.TMB_CLOSE(tmb)
    return pcm
end

-- source_in=750 frames = 30 seconds at 25fps (well into the mix, past any silent intro)
-- Without BWF adjustment (offset=0), this seeks to file position 30s
local pcm_no_bwf = decode_with_bwf_offset(0, 750, "no-bwf")
assert(pcm_no_bwf, "baseline decode returned nil")
local rms_no_bwf = pcm_rms(pcm_no_bwf)
check(rms_no_bwf > 0.001, string.format("baseline RMS=%.4f (non-silent)", rms_no_bwf))

-- ═══════════════════════════════════════════════════════════════
-- 2. Clip WITH bwf_offset_us (BWF adjustment expected)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2: With bwf_offset_us (BWF adjustment) ---")

-- Simulate: MST is 10 seconds BEFORE BWF origin (typical Pro Tools scenario).
-- bwf_offset = BWF_us - MST_us = bwf_us - (bwf_us - 10000000) = 10000000
-- TMB: file_seek = source_in_us - bwf_offset = 30s - 10s = 20s
-- Baseline seeks to 30s, adjusted seeks to 20s → different audio section.
local fake_bwf_offset = 10000000  -- BWF_us - MST_us where MST is 10s before BWF

local pcm_with_bwf = decode_with_bwf_offset(fake_bwf_offset, 750, "with-bwf")
assert(pcm_with_bwf, "BWF-adjusted decode returned nil")
local rms_with_bwf = pcm_rms(pcm_with_bwf)
check(rms_with_bwf > 0.001, string.format("adjusted RMS=%.4f (non-silent)", rms_with_bwf))

-- ═══════════════════════════════════════════════════════════════
-- 3. The two decodes MUST produce different audio
--    (proving BWF offset was applied)
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3: BWF adjustment produces different audio ---")

local s_no = pcm_first_samples(pcm_no_bwf, 128)
local s_with = pcm_first_samples(pcm_with_bwf, 128)

local match_count = 0
for i = 1, math.min(#s_no, #s_with) do
    if math.abs(s_no[i] - s_with[i]) < 1e-6 then match_count = match_count + 1 end
end

-- If BWF offset is applied, audio should differ (2 second shift in a stereo mix)
-- If NOT applied (current state), both decodes produce identical audio → FAIL
check(match_count < #s_no * 0.5,
    string.format("BWF-adjusted vs baseline: %d/%d identical (should differ)",
        match_count, #s_no))

-- ═══════════════════════════════════════════════════════════════
-- 4. TC alignment: adjusted audio should correspond to correct timeline TC
-- ═══════════════════════════════════════════════════════════════
print("\n--- 4: TC alignment verification ---")

-- source_in=750 at 25fps = 30.0 seconds of source offset
-- With bwf_offset=10000000: file_seek = 30s - 10s = 20.0s
-- Without adjustment: file_seek = 30.0s
-- Difference: 10 seconds apart in file position
local info_no = EMP.PCM_INFO(pcm_no_bwf)
local info_with = EMP.PCM_INFO(pcm_with_bwf)
check(info_no.frames > 0 and info_with.frames > 0,
    string.format("both decodes have frames (%d, %d)", info_no.frames, info_with.frames))

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
    print("\n  NOTE: Failures expected until BWF precompute is implemented.")
    print("  TMB must read bwf_offset_us from ClipInfo and adjust source seek.")
end
assert(failed == 0, string.format("FAILED: %d check(s) — BWF offset not applied", failed))
print("✅ test_tmb_bwf_offset.lua passed")
