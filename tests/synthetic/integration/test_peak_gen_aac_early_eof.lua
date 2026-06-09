-- Regression: peak generation must not abort when a file's container duration
-- overestimates the actual decodable audio.
--
-- Background: AAC/M4A containers encoded by Apple's afconvert (and many other
-- encoders) carry a non-zero start_pts (codec priming samples). MediaFileInfo
-- reports duration_us based on the full container span, but the decoder skips
-- the priming samples. PeakGenerator used to compute total_samples from
-- duration_us and decode forward chunk-by-chunk; on the last chunk the decoder
-- would hit real EOF and return a valid-success-with-zero-frames chunk (per
-- Reader::DecodeAudioRange contract). PeakGenerator treated that as an
-- invariant violation and called abort().
--
-- With 790 media items loaded at startup, any project containing a single
-- AAC file encoded this way would crash on open. The fixture used here is a
-- 1-second 440 Hz tone encoded with afconvert, which produces the same
-- start_pts=2112 priming pattern as the real offending SFX library files.
--
-- Run via: ./build/bin/jve --test tests/synthetic/integration/test_peak_gen_aac_early_eof.lua

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

print("--- test_peak_gen_aac_early_eof.lua ---")

local MEDIA_PATH = env.test_media_path("test_tone_1s_48k_stereo.m4a")
local PEAK_DIR = "/tmp/jve/test_peak_gen_aac_early_eof"
local PEAK_FILE = PEAK_DIR .. "/tone.peaks"
os.execute(string.format("rm -rf %q", PEAK_DIR))
os.execute(string.format("mkdir -p %q", PEAK_DIR))

-- ============================================================================
-- Step 1: Confirm fixture exhibits the container/decoder mismatch.
-- If this ever stops being true, the fixture was rebuilt with a different
-- encoder and no longer exercises the bug — fail loud.
-- ============================================================================
print("  step 1: confirm fixture has container/decoder mismatch")
local mf = assert(EMP.MEDIA_FILE_OPEN(MEDIA_PATH))
local info = EMP.MEDIA_FILE_INFO(mf)
assert(info.has_audio, "fixture has no audio stream")
local rate = info.audio_sample_rate
local predicted = math.floor(info.duration_us / 1e6 * rate)

local reader = assert(EMP.READER_CREATE(mf))
local actual = 0
while actual < predicted do
    local take = math.min(rate, predicted - actual)
    local pcm = assert(EMP.READER_DECODE_AUDIO_RANGE(
        reader, actual, actual + take, rate, 1, rate, 2))
    local pi = EMP.PCM_INFO(pcm)
    EMP.PCM_RELEASE(pcm)
    if pi.frames == 0 then break end
    actual = actual + pi.frames
end
EMP.READER_CLOSE(reader)
EMP.MEDIA_FILE_CLOSE(mf)

print(string.format("    predicted=%d actual=%d delta=%d",
    predicted, actual, actual - predicted))
assert(actual < predicted,
    "fixture no longer exhibits container/decoder mismatch — " ..
    "regenerate with afconvert -f m4af -d aac")

-- ============================================================================
-- Step 2: Request peak generation on the fixture.
--         Before fix: process aborts inside the worker thread.
--         After fix:  reaches "complete" state.
-- ============================================================================
print("  step 2: generate peaks (must not abort)")
EMP.PEAK_REQUEST("aac_priming_test", MEDIA_PATH, PEAK_FILE)

local deadline = os.time() + 30
while true do
    local status = EMP.PEAK_STATUS("aac_priming_test")
    if status and status.state == "complete" then break end
    if status and status.state == "failed" then
        error("peak generation reported failure")
    end
    assert(os.time() <= deadline, "peak generation timed out")
    for _ = 1, 1000000 do end
end
print("    OK — peak generation completed without abort")

-- ============================================================================
-- Step 3: Peak file opens and level-0 tail contains real data (not sentinel).
--         With the peak buffer trimmed to actual decoded samples, no bin in
--         the file should be stuck at the sentinel (min=1.0, max=-1.0) init
--         values — every bin was either written from real audio or does not
--         exist in the file at all.
-- ============================================================================
print("  step 3: verify no sentinel bins in generated peak file")
local peak_handle = assert(EMP.PEAK_LOAD(PEAK_FILE))
local header = EMP.PEAK_HEADER(peak_handle)

-- Lua is 1-indexed, so bins_per_level[1] is level 0.
local level0_bins = header.bins_per_level[1]
local base_spp = header.base_spp
local file_samples = level0_bins * base_spp
print(string.format("    header: level0_bins=%d base_spp=%d file_span=%d",
    level0_bins, base_spp, file_samples))

-- The file's level-0 span should not exceed actual decoded frames by more
-- than one bin (rounding up the final partial bin). If it does, FinalizeJob
-- is still allocating the buffer from the over-estimated predicted total.
assert(file_samples <= actual + base_spp,
    string.format("peak file spans %d samples but decoder only produced %d " ..
        "(base_spp=%d) — buffer was not trimmed to actual decoded frames",
        file_samples, actual, base_spp))
assert(file_samples > 0, "peak file reports zero level-0 bins")

-- Walk every level-0 bin and verify none is still at sentinel state.
-- Sentinel values come from AllocatePeakBuffer's init: min=1.0, max=-1.0.
-- A bin at sentinel means AccumulateSamplesToLevel0 never wrote to it —
-- which means the buffer was sized larger than actual decoded frames.
local sentinel_bins = 0
for bin = 0, level0_bins - 1 do
    local s0 = bin * base_spp
    local s1 = s0 + base_spp
    local peaks, count = EMP.PEAK_QUERY(peak_handle, s0, s1, 1)
    assert(peaks and count == 1,
        string.format("PEAK_QUERY failed for bin %d", bin))
    local pd = ffi.cast("float*", peaks)
    if pd[0] >= 0.999 and pd[1] <= -0.999 then
        sentinel_bins = sentinel_bins + 1
    end
end
EMP.PEAK_RELEASE(peak_handle)

assert(sentinel_bins == 0,
    string.format("%d/%d bins still at sentinel (min=1,max=-1) — " ..
        "peak buffer was not trimmed to actual decoded frames",
        sentinel_bins, level0_bins))

print(string.format("    OK — all %d bins contain real data", level0_bins))

print("✅ test_peak_gen_aac_early_eof.lua passed")
