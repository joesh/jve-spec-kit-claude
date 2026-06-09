-- Regression test: peak generator sample-position accuracy
--
-- Verifies that peak bins at all file positions accurately represent the
-- audio at those positions, using independently decoded ground truth.
--
-- Uses varied_amplitude_aac_34s.mp4 (synthetic AAC stereo, 34s):
-- pink noise enveloped by a slow sine + periodic full-scale transient
-- bursts every ~3s. The amplitude variation makes positional drift
-- detectable — shifted bins produce measurably different min/max
-- values. AAC encoding is required because this test verifies peak
-- bin alignment across AAC frame boundaries (1024 samples), which is
-- meaningless for raw PCM source files.
--
-- Method: "fingerprint" approach —
--   1. Decode audio independently at positions across the file
--   2. Compute ground-truth min/max for each 256-sample bin
--   3. Generate peaks for the same file
--   4. Query peak data at the same positions using provenance tags
--   5. Assert fingerprints match — especially at late positions
--      where cumulative drift would be largest
--
-- Run via: ./build/bin/jve --test tests/synthetic/integration/test_peak_drift_regression.lua

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

print("--- test_peak_drift_regression.lua ---")

-- Synthetic AAC stereo with deliberate amplitude variation (see header).
local MEDIA_PATH = env.test_media_path("varied_amplitude_aac_34s.mp4")
local PEAK_DIR = "/tmp/jve/test_peak_drift"
local PEAK_FILE = PEAK_DIR .. "/drift_test.peaks"
os.execute(string.format("rm -rf %q", PEAK_DIR))
os.execute(string.format("mkdir -p %q", PEAK_DIR))

local BIN_SIZE = 256  -- BASE_SAMPLES_PER_PEAK

-- ============================================================================
-- Step 1: Open media, get audio properties
-- ============================================================================
print("  step 1: open media")
local mf = assert(EMP.MEDIA_FILE_OPEN(MEDIA_PATH))
local info = EMP.MEDIA_FILE_INFO(mf)
assert(info.has_audio, "test media must have audio")
print(string.format("    sr=%d ch=%d duration_us=%d",
    info.audio_sample_rate, info.audio_channels, info.duration_us))

local total_samples = math.floor(info.duration_us / 1000000.0 * info.audio_sample_rate)
print(string.format("    total_samples=%d (%.1fs)", total_samples,
    total_samples / info.audio_sample_rate))

-- ============================================================================
-- Step 2: Decode ground-truth fingerprints at multiple positions
-- ============================================================================
print("  step 2: decode ground-truth fingerprints")

-- Positions spread across the file at sharp energy transitions.
-- Late positions (19s+) are where cumulative drift would be largest.
--
-- IMPORTANT: Snap to AAC frame boundaries (1024 samples), not just peak
-- bin boundaries (256 samples). AAC seek resolution is one codec frame.
-- A fresh-reader seek to a non-frame-aligned position returns the
-- enclosing frame's data, not the exact requested position. This makes
-- ground truth invalid at non-aligned positions. Since 1024 = 4 * 256,
-- aligned positions are every 4th peak bin.
local AAC_FRAME = 1024  -- AAC-LC codec frame size in samples
local fingerprint_positions = {
    { sample = 0,                           label = "0s (start)" },
    { sample = 3 * info.audio_sample_rate,  label = "3s (transient)" },
    { sample = 9 * info.audio_sample_rate,  label = "9s" },
    { sample = 15 * info.audio_sample_rate, label = "15s" },
    { sample = 19 * info.audio_sample_rate, label = "19s (loud)" },
    { sample = 20 * info.audio_sample_rate, label = "20s (drop)" },
    { sample = 29 * info.audio_sample_rate, label = "29s" },
    { sample = 34 * info.audio_sample_rate, label = "34s (end)" },
}

-- Snap to AAC frame boundary (which is also a bin boundary since 1024 % 256 == 0)
local valid_positions = {}
for _, pos in ipairs(fingerprint_positions) do
    pos.sample = math.floor(pos.sample / AAC_FRAME) * AAC_FRAME
    if pos.sample + BIN_SIZE <= total_samples then
        table.insert(valid_positions, pos)
    end
end
fingerprint_positions = valid_positions
assert(#fingerprint_positions >= 6,
    "need at least 6 valid fingerprint positions for meaningful drift detection")

--- Decode one bin of audio and return ground-truth min/max across all channels.
local function decode_fingerprint(target_sample)
    local rd = assert(EMP.READER_CREATE(mf))
    local pcm = assert(EMP.READER_DECODE_AUDIO_RANGE(rd,
        target_sample, target_sample + BIN_SIZE,
        info.audio_sample_rate, 1,  -- rate = sample_rate/1 (frames = samples)
        info.audio_sample_rate, info.audio_channels))
    local pi = EMP.PCM_INFO(pcm)
    assert(pi.frames > 0,
        string.format("decoded 0 frames at sample %d", target_sample))

    local samples = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))
    local mn, mx = 1.0, -1.0
    local nf = math.min(BIN_SIZE, pi.frames)
    for s = 0, nf - 1 do
        for ch = 0, pi.channels - 1 do
            local v = samples[s * pi.channels + ch]
            if v < mn then mn = v end
            if v > mx then mx = v end
        end
    end
    EMP.PCM_RELEASE(pcm)
    EMP.READER_CLOSE(rd)
    return mn, mx
end

for _, pos in ipairs(fingerprint_positions) do
    pos.gt_min, pos.gt_max = decode_fingerprint(pos.sample)
    print(string.format("    %s (sample %d): min=%.6f max=%.6f",
        pos.label, pos.sample, pos.gt_min, pos.gt_max))
end

-- ============================================================================
-- Step 3: Generate peaks
-- ============================================================================
print("  step 3: generate peaks")
os.remove(PEAK_FILE)
EMP.PEAK_REQUEST("drift_test", MEDIA_PATH, PEAK_FILE)

local deadline = os.time() + 60
while true do
    local status = EMP.PEAK_STATUS("drift_test")
    if status and status.state == "complete" then break end
    if status and status.state == "failed" then error("peak generation failed") end
    assert(os.time() <= deadline, "peak generation timed out (60s)")
    for _ = 1, 1000000 do end  -- busy-wait
end
print("    peak file generated")

-- ============================================================================
-- Step 4: Load peak file
-- ============================================================================
print("  step 4: load peak file")
local peak_handle = assert(EMP.PEAK_LOAD(PEAK_FILE))
local hdr = assert(EMP.PEAK_HEADER(peak_handle), "peak header is nil")
print(string.format("    peak: sr=%d ch=%d levels=%d bins_l0=%d",
    hdr.sample_rate, hdr.channels, hdr.num_levels, hdr.bins_per_level[1]))

-- ============================================================================
-- Step 5: Verify fingerprints match peak data at each position
-- ============================================================================
print("  step 5: verify fingerprints via provenance-tagged peak queries")

-- Tolerance: at AAC-frame-aligned positions, seek and sequential decode
-- produce identical audio. Small differences come from resampler FIR
-- filter state. Real drift shifts bins by hundreds of positions, producing
-- errors orders of magnitude larger than this tolerance.
local TOLERANCE = 0.02

local max_observed_error = 0
local failures = {}

for _, pos in ipairs(fingerprint_positions) do
    local peaks, count, actual_start, actual_end =
        EMP.PEAK_QUERY(peak_handle, pos.sample, pos.sample + BIN_SIZE, 1)
    assert(peaks, string.format("PEAK_QUERY nil at %s (sample %d)", pos.label, pos.sample))
    assert(count == 1, string.format("expected 1 pair at %s, got %d", pos.label, count))

    -- Provenance: actual range must encompass the requested bin
    assert(actual_start <= pos.sample,
        string.format("provenance: actual_start (%d) > requested (%d) at %s",
            actual_start, pos.sample, pos.label))
    assert(actual_end >= pos.sample + BIN_SIZE,
        string.format("provenance: actual_end (%d) < requested end (%d) at %s",
            actual_end, pos.sample + BIN_SIZE, pos.label))

    local pd = ffi.cast("float*", peaks)
    local pk_min, pk_max = pd[0], pd[1]

    local min_err = math.abs(pk_min - pos.gt_min)
    local max_err = math.abs(pk_max - pos.gt_max)
    local err = math.max(min_err, max_err)
    if err > max_observed_error then max_observed_error = err end

    local status_tag = err < TOLERANCE and "OK" or "DRIFT"
    print(string.format("    %s: peak=[%.6f,%.6f] gt=[%.6f,%.6f] err=%.6f %s",
        pos.label, pk_min, pk_max, pos.gt_min, pos.gt_max, err, status_tag))

    if err >= TOLERANCE then
        table.insert(failures, string.format(
            "DRIFT at %s (sample %d): peak=[%.6f,%.6f] gt=[%.6f,%.6f] err=%.6f",
            pos.label, pos.sample, pk_min, pk_max, pos.gt_min, pos.gt_max, err))
    end
end

print(string.format("    max observed error: %.6f (tolerance: %.6f)",
    max_observed_error, TOLERANCE))

-- ============================================================================
-- Step 6: Report
-- ============================================================================
if #failures > 0 then
    print("")
    print("  FAILURES:")
    for _, msg in ipairs(failures) do
        print("    " .. msg)
    end
    error(string.format(
        "Peak drift detected: %d/%d positions failed (max err=%.6f). "
        .. "Peak data does not match independently decoded audio.",
        #failures, #fingerprint_positions, max_observed_error))
end

-- ============================================================================
-- Step 7: Boundary tests — first and last bins
-- ============================================================================
print("  step 7: boundary tests")

-- First bin: sample 0
local first_peaks, first_count, first_start, _ =
    EMP.PEAK_QUERY(peak_handle, 0, BIN_SIZE, 1)
assert(first_peaks and first_count == 1,
    "boundary: first bin query failed")
assert(first_start == 0,
    string.format("boundary: first bin actual_start=%d, expected 0", first_start))
print("    first bin: OK")

-- Last bin: aligned to end of file
local last_bin_start = math.floor((total_samples - 1) / BIN_SIZE) * BIN_SIZE
local last_peaks, last_count, last_start, _ =
    EMP.PEAK_QUERY(peak_handle, last_bin_start, last_bin_start + BIN_SIZE, 1)
assert(last_peaks and last_count == 1,
    string.format("boundary: last bin query failed at sample %d", last_bin_start))
assert(last_start <= last_bin_start,
    string.format("boundary: last bin actual_start (%d) > requested (%d)",
        last_start, last_bin_start))
print(string.format("    last bin (sample %d): OK", last_bin_start))

-- ============================================================================
-- Step 8: Out-of-range query — must return nil/0, not garbage
-- ============================================================================
print("  step 8: out-of-range queries")

local oor_peaks, oor_count = EMP.PEAK_QUERY(peak_handle, total_samples + 100000, total_samples + 200000, 100)
assert(not oor_peaks or oor_count == 0,
    "out-of-range query past file end must return nil or count=0")
print("    past-end query: correctly empty")

local neg_peaks, neg_count = EMP.PEAK_QUERY(peak_handle, -1000, -500, 100)
assert(not neg_peaks or neg_count == 0,
    "negative-range query must return nil or count=0")
print("    negative query: correctly empty")

-- Cleanup
EMP.PEAK_RELEASE(peak_handle)
EMP.MEDIA_FILE_CLOSE(mf)
os.execute(string.format("rm -rf %q", PEAK_DIR))

print("✅ test_peak_drift_regression.lua passed")
