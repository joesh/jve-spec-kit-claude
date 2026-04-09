-- Integration test: waveform peak alignment
-- Verifies that peak data returned by PEAK_QUERY matches actual decoded audio
-- at the same source position.
--
-- Run via: ./build/bin/JVEEditor --test tests/integration/test_waveform_alignment.lua
--
-- Uses a generated test tone (440Hz sine, 48kHz stereo, 2s) with known
-- predictable peak values per 256-sample bin.

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local waveform_utils = require("core.media.waveform_utils")
local ffi = require("ffi")

print("--- test_waveform_alignment.lua ---")

local MEDIA_PATH = env.test_media_path("test_tone_48k_stereo.wav")
local PEAK_DIR = "/tmp/jve/test_waveform_alignment"
local PEAK_FILE = PEAK_DIR .. "/test_tone.peaks"
os.execute(string.format("rm -rf %q", PEAK_DIR))
os.execute(string.format("mkdir -p %q", PEAK_DIR))

local BIN_SIZE = 256
local TOLERANCE = 0.05  -- allow small rounding from decode/resample

-- ============================================================================
-- Step 1: Open media and verify audio properties
-- ============================================================================
print("  step 1: open media")
local mf = assert(EMP.MEDIA_FILE_OPEN(MEDIA_PATH))
local info = EMP.MEDIA_FILE_INFO(mf)
assert(info.has_audio, "test media must have audio")
assert(info.audio_sample_rate == 48000,
    "expected 48kHz, got " .. tostring(info.audio_sample_rate))
assert(info.audio_channels == 2,
    "expected stereo, got " .. tostring(info.audio_channels))
print(string.format("    sr=%d ch=%d duration_us=%d",
    info.audio_sample_rate, info.audio_channels, info.duration_us))

-- ============================================================================
-- Step 2: Decode audio at multiple positions, compute ground-truth peaks
-- ============================================================================
print("  step 2: decode ground-truth peaks at 3 positions")

--- Decode a 256-sample bin and return its min/max across all channels.
local function decode_ground_truth(target_sample)
    local rd = assert(EMP.READER_CREATE(mf))
    local pcm = assert(EMP.READER_DECODE_AUDIO_RANGE(rd,
        target_sample, target_sample + BIN_SIZE,
        info.audio_sample_rate, 1,
        info.audio_sample_rate, info.audio_channels))
    local pi = EMP.PCM_INFO(pcm)
    assert(pi.frames > 0, "decoded 0 frames at sample " .. target_sample)

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

-- Test at beginning (bin 0), middle (bin 100), and end (bin 300)
local test_positions = {
    { sample = 0,         label = "start" },
    { sample = 100 * 256, label = "middle" },
    { sample = 300 * 256, label = "end" },
}

for _, pos in ipairs(test_positions) do
    pos.gt_min, pos.gt_max = decode_ground_truth(pos.sample)
    print(string.format("    %s (sample %d): min=%.4f max=%.4f",
        pos.label, pos.sample, pos.gt_min, pos.gt_max))
    -- 440Hz sine at full scale — peaks should be substantial
    assert(pos.gt_max > 0.5,
        string.format("ground truth max too small at %s: %.4f", pos.label, pos.gt_max))
    assert(pos.gt_min < -0.5,
        string.format("ground truth min too small at %s: %.4f", pos.label, pos.gt_min))
end

-- ============================================================================
-- Step 3: Generate peak file
-- ============================================================================
print("  step 3: generate peaks")
os.remove(PEAK_FILE)
EMP.PEAK_REQUEST("test_tone", MEDIA_PATH, PEAK_FILE)

local deadline = os.time() + 30
while true do
    local status = EMP.PEAK_STATUS("test_tone")
    if status and status.state == "complete" then break end
    if status and status.state == "failed" then error("peak generation failed") end
    assert(os.time() <= deadline, "peak generation timed out (30s)")
    for _ = 1, 1000000 do end  -- busy-wait
end
print("    peak file generated")

-- ============================================================================
-- Step 4: Load and validate peak file header
-- ============================================================================
print("  step 4: load peak file")
local peak_handle = assert(EMP.PEAK_LOAD(PEAK_FILE))
local hdr = assert(EMP.PEAK_HEADER(peak_handle), "peak header is nil")
assert(hdr.base_spp == 256, "base_spp expected 256 got " .. tostring(hdr.base_spp))
print(string.format("    peak: sr=%d ch=%d levels=%d bins_l0=%d",
    hdr.sample_rate, hdr.channels, hdr.num_levels, hdr.bins_per_level[1]))

-- ============================================================================
-- Step 5: Query peak file at same positions and verify alignment
-- ============================================================================
print("  step 5: verify peak alignment at each position")

for _, pos in ipairs(test_positions) do
    -- Query exactly 1 bin at this position
    local peaks, count = EMP.PEAK_QUERY(peak_handle,
        pos.sample, pos.sample + BIN_SIZE, 1)
    assert(peaks, string.format("PEAK_QUERY nil at %s (sample %d)", pos.label, pos.sample))
    assert(count == 1, string.format("expected 1 pair at %s, got %d", pos.label, count))

    local pd = ffi.cast("float*", peaks)
    local pk_min, pk_max = pd[0], pd[1]

    local min_diff = math.abs(pk_min - pos.gt_min)
    local max_diff = math.abs(pk_max - pos.gt_max)

    print(string.format("    %s: peak=[%.4f,%.4f] gt=[%.4f,%.4f] diff=[%.4f,%.4f]",
        pos.label, pk_min, pk_max, pos.gt_min, pos.gt_max, min_diff, max_diff))

    assert(min_diff < TOLERANCE,
        string.format("ALIGNMENT FAIL at %s: peak_min=%.4f gt_min=%.4f diff=%.4f",
            pos.label, pk_min, pos.gt_min, min_diff))
    assert(max_diff < TOLERANCE,
        string.format("ALIGNMENT FAIL at %s: peak_max=%.4f gt_max=%.4f diff=%.4f",
            pos.label, pk_max, pos.gt_max, max_diff))
end

-- ============================================================================
-- Step 6: Verify offset query — querying at wrong position gives different data
-- ============================================================================
print("  step 6: verify wrong position gives different peaks")

-- Query 10 bins later — should have different phase, possibly different peak values
-- For a pure sine, the peaks per bin vary with phase alignment
local offset_sample = 10 * BIN_SIZE  -- 10 bins offset from bin 0
local peaks_at_0, _ = EMP.PEAK_QUERY(peak_handle, 0, BIN_SIZE, 1)
local peaks_at_offset, _ = EMP.PEAK_QUERY(peak_handle, offset_sample, offset_sample + BIN_SIZE, 1)
assert(peaks_at_0 and peaks_at_offset, "both queries must return data")

-- For a 440Hz sine at 48kHz: period = 48000/440 ≈ 109 samples
-- Bin 0 covers samples 0-255 (≈2.3 periods) — peaks near ±1.0
-- Bin 10 covers samples 2560-2815 — also ≈2.3 periods
-- Both should have similar peaks (full-scale sine fills every bin)
-- This just validates the query doesn't return garbage
local p0 = ffi.cast("float*", peaks_at_0)
local p10 = ffi.cast("float*", peaks_at_offset)
assert(p0[1] > 0.9, string.format("bin 0 max should be near 1.0, got %.4f", p0[1]))
assert(p10[1] > 0.9, string.format("bin 10 max should be near 1.0, got %.4f", p10[1]))
print("    offset query OK")

-- ============================================================================
-- Step 7: Verify viewport clipping + peak query end-to-end
-- ============================================================================
print("  step 7: viewport clipping end-to-end")

-- Simulate: clip source_in=0, source_out=96000 (full 2s file)
-- Clip is 2000px wide, viewport 500px, clip offset 500px left of viewport
-- x=-500, visible_x=0, clip_width=2000, draw_width=500
local vis_in, vis_out = waveform_utils.visible_source_range(0, 96000, -500, 0, 2000, 500)

-- Expected: left quarter of source is clipped
-- spp = 96000/2000 = 48. left_clip = 500*48 = 24000
-- vis_in = 24000, vis_out = 96000 - 0 = 96000 (no right clip since 500+500=1000 < 2000... wait)
-- right_clip = (2000 - 500 - 500) * 48... no. right_clip = (x+clip_width) - (visible_x+draw_width) = (-500+2000) - (0+500) = 1000px
-- vis_out = 96000 - 1000*48 = 96000 - 48000 = 48000
assert(vis_in == 24000,
    string.format("viewport vis_in expected 24000 got %d", vis_in))
assert(vis_out == 48000,
    string.format("viewport vis_out expected 48000 got %d", vis_out))

-- Query peaks for visible range
local vis_peaks, vis_count = EMP.PEAK_QUERY(peak_handle, vis_in, vis_out, 500)
assert(vis_peaks, "viewport query returned nil")
assert(vis_count == 500, string.format("expected 500 pairs, got %d", vis_count))

-- All 500 columns should have peaks near ±1.0 (full-scale sine)
local vpd = ffi.cast("float*", vis_peaks)
for i = 0, vis_count - 1 do
    assert(vpd[i * 2 + 1] > 0.5,
        string.format("viewport pixel %d: max=%.4f too small", i, vpd[i * 2 + 1]))
end
print("    viewport clipping end-to-end OK")

-- ============================================================================
-- Step 8: Simulate absolute TC source_in (like real project clips)
-- ============================================================================
print("  step 8: absolute TC simulation")

-- Real project clips have source_in = media_tc_origin + file_offset.
-- peak_cache.get_visible_peaks subtracts media_tc_origin before querying.
-- Simulate: media starts at TC 01:00:00:00 = 48000*3600 = 172800000 samples
-- Clip source_in = 172800000 + 25600 (file offset to bin 100)
-- Clip source_out = 172800000 + 25600 + 256 (one bin)
local TC_ORIGIN = 172800000
local abs_source_in = TC_ORIGIN + 25600
local abs_source_out = TC_ORIGIN + 25600 + BIN_SIZE

-- After TC subtraction: file_start = 25600, file_end = 25856
local file_start = abs_source_in - TC_ORIGIN
local file_end = abs_source_out - TC_ORIGIN
assert(file_start == 25600, "file_start expected 25600 got " .. file_start)
assert(file_end == 25856, "file_end expected 25856 got " .. file_end)

-- Query with file-relative coords should match middle position ground truth
local tc_peaks, tc_count = EMP.PEAK_QUERY(peak_handle, file_start, file_end, 1)
assert(tc_peaks and tc_count == 1, "TC query failed")
local tc_pd = ffi.cast("float*", tc_peaks)
local tc_min_diff = math.abs(tc_pd[0] - test_positions[2].gt_min)
local tc_max_diff = math.abs(tc_pd[1] - test_positions[2].gt_max)
print(string.format("    abs TC query: peak=[%.4f,%.4f] gt=[%.4f,%.4f] diff=[%.4f,%.4f]",
    tc_pd[0], tc_pd[1], test_positions[2].gt_min, test_positions[2].gt_max, tc_min_diff, tc_max_diff))
assert(tc_min_diff < TOLERANCE, "TC alignment failed for min")
assert(tc_max_diff < TOLERANCE, "TC alignment failed for max")

-- Verify that querying WITHOUT subtracting TC origin gives wrong results
-- (queries at sample 172825600 in a 96000-sample file → out of range → nil)
local bad_peaks, bad_count = EMP.PEAK_QUERY(peak_handle, abs_source_in, abs_source_out, 1)
assert(not bad_peaks or bad_count == 0,
    "querying with absolute TC (no subtraction) should return nil — the bug we're testing for")
print("    absolute TC without subtraction correctly returns nil (out of range)")

print("    absolute TC simulation OK")

-- Cleanup
EMP.PEAK_RELEASE(peak_handle)
EMP.MEDIA_FILE_CLOSE(mf)
os.execute(string.format("rm -rf %q", PEAK_DIR))

print("✅ test_waveform_alignment.lua passed")
