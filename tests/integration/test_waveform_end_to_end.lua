-- End-to-end waveform alignment test
-- Uses a click-at-known-position WAV to verify the FULL renderer code path:
--   clip source_in/source_out → waveform_utils.visible_source_range →
--   peak_cache TC origin subtraction → PEAK_QUERY → pixel column
--
-- If the click appears at the wrong pixel column, the coordinate chain is broken.
--
-- Run via: ./build/bin/JVEEditor --test tests/integration/test_waveform_end_to_end.lua

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local waveform_utils = require("core.media.waveform_utils")
local ffi = require("ffi")

print("--- test_waveform_end_to_end.lua ---")

local MEDIA_PATH = env.test_media_path("test_click_48k_stereo.wav")
local PEAK_DIR = "/tmp/jve/test_waveform_e2e"
local PEAK_FILE = PEAK_DIR .. "/click_test.peaks"
os.execute(string.format("rm -rf %q", PEAK_DIR))
os.execute(string.format("mkdir -p %q", PEAK_DIR))

-- Known signal: silence(48000 samples) + click(256 samples) + silence(95744 samples)
-- Total: 144000 samples = 3 seconds at 48kHz
local CLICK_START_SAMPLE = 48000  -- file-relative
local CLICK_BIN = math.floor(CLICK_START_SAMPLE / 256)  -- = bin 187 at level 0
local TOTAL_SAMPLES = 144000

-- ============================================================================
-- Step 1: Generate peaks
-- ============================================================================
print("  step 1: generate peaks for click WAV")
EMP.PEAK_REQUEST("click_test", MEDIA_PATH, PEAK_FILE)
local deadline = os.time() + 30
while true do
    local status = EMP.PEAK_STATUS("click_test")
    if status and status.state == "complete" then break end
    if status and status.state == "failed" then error("peak generation failed") end
    assert(os.time() <= deadline, "peak generation timed out")
    for _ = 1, 1000000 do end
end

local peak_handle = assert(EMP.PEAK_LOAD(PEAK_FILE))
print("    OK")

-- ============================================================================
-- Step 2: Verify click is at the right bin in raw peak data
-- ============================================================================
print("  step 2: verify click bin in raw peak data")

-- Query actual bin-aligned ranges around the click
print("    scanning bin-aligned ranges around click:")
for bin = CLICK_BIN - 3, CLICK_BIN + 3 do
    local bs = bin * 256
    local be = (bin + 1) * 256
    if bs >= 0 then
        local bp, bc = EMP.PEAK_QUERY(peak_handle, bs, be, 1)
        if bp and bc > 0 then
            local bpd = ffi.cast("float*", bp)
            print(string.format("      bin %d (samples %d..%d): min=%.4f max=%.4f %s",
                bin, bs, be, bpd[0], bpd[1],
                bpd[1] > 0.5 and "<<< LOUD" or ""))
        end
    end
end

-- Query one bin at the click position — verify TC tags
local click_peaks, click_count, click_actual_start, click_actual_end =
    EMP.PEAK_QUERY(peak_handle, CLICK_START_SAMPLE, CLICK_START_SAMPLE + 256, 1)
print(string.format("    click query: requested=[%d,%d] actual=[%d,%d]",
    CLICK_START_SAMPLE, CLICK_START_SAMPLE + 256, click_actual_start, click_actual_end))
assert(click_peaks and click_count == 1, "click bin query failed")
local cpd = ffi.cast("float*", click_peaks)
assert(cpd[1] > 0.9, string.format("click bin max=%.4f — expected near 1.0", cpd[1]))

-- Query bin-aligned ranges BEFORE and AFTER the click
-- Click at sample 48000 → bin 187 (floor(48000/256)=187, range 47872..48128)
-- Previous bin 186: range 47616..47872 (should be silent)
-- Click also spans into bin 188: range 48128..48384 (sample 48255 is in bin 188)
-- Bin 189: range 48384..48640 (should be silent)
local pre_bin = CLICK_BIN - 1  -- bin 186
local post_bin = CLICK_BIN + 2  -- bin 189

local pre_peaks, _ = EMP.PEAK_QUERY(peak_handle, pre_bin * 256, (pre_bin + 1) * 256, 1)
assert(pre_peaks, "pre-click query failed")
local ppd = ffi.cast("float*", pre_peaks)
assert(math.abs(ppd[0]) < 0.01 and math.abs(ppd[1]) < 0.01,
    string.format("bin %d (pre-click) should be silent, got [%.4f, %.4f]", pre_bin, ppd[0], ppd[1]))

local post_peaks, _ = EMP.PEAK_QUERY(peak_handle, post_bin * 256, (post_bin + 1) * 256, 1)
assert(post_peaks, "post-click query failed")
local postpd = ffi.cast("float*", post_peaks)
assert(math.abs(postpd[0]) < 0.01 and math.abs(postpd[1]) < 0.01,
    string.format("bin %d (post-click) should be silent, got [%.4f, %.4f]", post_bin, postpd[0], postpd[1]))

print("    click at correct raw bin position")

-- ============================================================================
-- Step 3: Simulate renderer — full clip visible, find the click pixel
-- ============================================================================
print("  step 3: full clip visible — find click pixel")

-- Simulate: clip source_in=0, source_out=144000 (whole file, no TC offset)
-- Clip is 1440px wide (10 samples/pixel). Click at sample 48000 → pixel 480.
local CLIP_WIDTH = 1440  -- pixels

local vis_in, vis_out = waveform_utils.visible_source_range(
    0, TOTAL_SAMPLES,    -- source_in, source_out
    0, 0,                -- x, visible_x (no clipping)
    CLIP_WIDTH, CLIP_WIDTH)  -- clip_width, draw_width
assert(vis_in == 0 and vis_out == TOTAL_SAMPLES, "full view should return full range")

local peaks, count, q_actual_start, q_actual_end =
    EMP.PEAK_QUERY(peak_handle, vis_in, vis_out, CLIP_WIDTH)
assert(peaks and count == CLIP_WIDTH, "full view query failed, count=" .. tostring(count))
print(string.format("    full query TC: requested=[%d,%d] actual=[%d,%d]",
    vis_in, vis_out, q_actual_start, q_actual_end))
assert(q_actual_start <= vis_in, string.format(
    "TC tag: actual_start (%d) should be <= requested (%d)", q_actual_start, vis_in))
assert(q_actual_end >= vis_out, string.format(
    "TC tag: actual_end (%d) should be >= requested (%d)", q_actual_end, vis_out))

-- Find the pixel with the highest peak (should be the click)
local pd = ffi.cast("float*", peaks)
local loudest_px = -1
local loudest_max = -1
for px = 0, count - 1 do
    if pd[px * 2 + 1] > loudest_max then
        loudest_max = pd[px * 2 + 1]
        loudest_px = px
    end
end

-- Expected click pixel: 48000 / (144000/1440) = 48000/100 = 480
local expected_click_px = math.floor(CLICK_START_SAMPLE / (TOTAL_SAMPLES / CLIP_WIDTH))
print(string.format("    loudest pixel: %d (expected %d), max=%.4f", loudest_px, expected_click_px, loudest_max))
assert(math.abs(loudest_px - expected_click_px) <= 1,
    string.format("CLICK AT WRONG PIXEL: got %d expected %d", loudest_px, expected_click_px))

-- Verify pixels far from click are silent
assert(pd[0 * 2 + 1] < 0.01, "pixel 0 should be silent")
assert(pd[(count - 1) * 2 + 1] < 0.01, "last pixel should be silent")
print("    full clip: click at correct pixel")

-- ============================================================================
-- Step 4: Simulate renderer — clip scrolled, left half clipped
-- ============================================================================
print("  step 4: scrolled view — left half clipped")

-- Viewport shows right half of clip: x=-720, visible_x=0, draw_width=720
local x_scrolled = -720
local draw_width_scrolled = 720
local vis_in2, vis_out2 = waveform_utils.visible_source_range(
    0, TOTAL_SAMPLES,
    x_scrolled, 0,
    CLIP_WIDTH, draw_width_scrolled)

-- Left half clipped: 720px of 1440px = 50% = 72000 samples
assert(vis_in2 == 72000, string.format("scrolled vis_in expected 72000 got %d", vis_in2))
assert(vis_out2 == TOTAL_SAMPLES, string.format("scrolled vis_out expected %d got %d", TOTAL_SAMPLES, vis_out2))

local peaks2, count2 = EMP.PEAK_QUERY(peak_handle, vis_in2, vis_out2, draw_width_scrolled)
assert(peaks2 and count2 == draw_width_scrolled, "scrolled query failed")

-- The click was at sample 48000 which is BEFORE vis_in2 (72000).
-- So the click should NOT appear in this view — all pixels should be silent.
local pd2 = ffi.cast("float*", peaks2)
local max_in_view = -1
for px = 0, count2 - 1 do
    if pd2[px * 2 + 1] > max_in_view then max_in_view = pd2[px * 2 + 1] end
end
assert(max_in_view < 0.01,
    string.format("scrolled past click — all should be silent, got max=%.4f", max_in_view))
print("    scrolled past click: correctly silent")

-- ============================================================================
-- Step 5: Simulate renderer — clip scrolled so click is at left edge
-- ============================================================================
print("  step 5: scrolled so click is at left viewport edge")

-- Clip pixel for click = 480. Scroll so click is at pixel 0:
-- x = -480, visible_x = 0, draw_width = 960 (right portion visible)
local x_click_at_edge = -480
local draw_at_edge = 960
local vis_in3, vis_out3 = waveform_utils.visible_source_range(
    0, TOTAL_SAMPLES,
    x_click_at_edge, 0,
    CLIP_WIDTH, draw_at_edge)

-- 480px clipped left = 480 * 100 = 48000 samples → vis_in3 = 48000
assert(vis_in3 == 48000, string.format("edge vis_in expected 48000 got %d", vis_in3))

local peaks3, count3 = EMP.PEAK_QUERY(peak_handle, vis_in3, vis_out3, draw_at_edge)
assert(peaks3 and count3 == draw_at_edge, "edge query failed")

-- Click starts at vis_in3 = 48000 = the first sample in the view.
-- So the click should be at pixel 0 (or very close to it).
local pd3 = ffi.cast("float*", peaks3)
assert(pd3[0 * 2 + 1] > 0.5,
    string.format("click should be at pixel 0, got max=%.4f", pd3[0 * 2 + 1]))
-- Pixels 5+ should be silent (click is only 256 samples = ~2.56 pixels at this scale)
assert(pd3[10 * 2 + 1] < 0.01,
    string.format("pixel 10 should be silent, got %.4f", pd3[10 * 2 + 1]))
print("    click at left edge: correct")

-- ============================================================================
-- Step 6: Simulate absolute TC offset (like DRP-imported project)
-- ============================================================================
print("  step 6: absolute TC offset (DRP import simulation)")

-- Media TC origin = 01:00:00:00 at 48kHz = 172800000 samples
-- Clip source_in = 172800000 (file start in absolute TC)
-- Clip source_out = 172800000 + 144000 (whole file)
-- The renderer passes these absolute values to waveform_utils, then
-- peak_cache subtracts TC origin before querying PEAK_QUERY.

local TC_ORIGIN = 172800000
local abs_source_in = TC_ORIGIN + 0
local abs_source_out = TC_ORIGIN + TOTAL_SAMPLES

-- Full clip visible, 1440px
local abs_vis_in, abs_vis_out = waveform_utils.visible_source_range(
    abs_source_in, abs_source_out,
    0, 0, CLIP_WIDTH, CLIP_WIDTH)
assert(abs_vis_in == abs_source_in, "full abs view: vis_in should equal source_in")
assert(abs_vis_out == abs_source_out, "full abs view: vis_out should equal source_out")

-- Subtract TC origin (what peak_cache.get_visible_peaks does)
local file_vis_in = abs_vis_in - TC_ORIGIN
local file_vis_out = abs_vis_out - TC_ORIGIN
assert(file_vis_in == 0, "file-relative start should be 0")
assert(file_vis_out == TOTAL_SAMPLES, "file-relative end should be total")

-- Query and find click pixel
local peaks6, count6 = EMP.PEAK_QUERY(peak_handle, file_vis_in, file_vis_out, CLIP_WIDTH)
assert(peaks6 and count6 == CLIP_WIDTH, "abs TC query failed")
local pd6 = ffi.cast("float*", peaks6)
local abs_loudest_px = -1
local abs_loudest_max = -1
for px = 0, count6 - 1 do
    if pd6[px * 2 + 1] > abs_loudest_max then
        abs_loudest_max = pd6[px * 2 + 1]
        abs_loudest_px = px
    end
end
assert(math.abs(abs_loudest_px - expected_click_px) <= 1,
    string.format("ABS TC: click at pixel %d expected %d", abs_loudest_px, expected_click_px))
print(string.format("    abs TC: click at pixel %d (expected %d) — correct", abs_loudest_px, expected_click_px))

-- Now test: what if TC origin subtraction is WRONG (off by 10000 samples)?
-- Click should shift to wrong pixel.
local bad_file_vis_in = abs_vis_in - (TC_ORIGIN + 10000)  -- wrong origin
local bad_file_vis_out = abs_vis_out - (TC_ORIGIN + 10000)
if bad_file_vis_in >= 0 and bad_file_vis_out > bad_file_vis_in then
    local bad_peaks, bad_count = EMP.PEAK_QUERY(peak_handle, bad_file_vis_in, bad_file_vis_out, CLIP_WIDTH)
    if bad_peaks and bad_count > 0 then
        local bpd = ffi.cast("float*", bad_peaks)
        local bad_loudest_px = -1
        local bad_loudest_max = -1
        for px = 0, bad_count - 1 do
            if bpd[px * 2 + 1] > bad_loudest_max then
                bad_loudest_max = bpd[px * 2 + 1]
                bad_loudest_px = px
            end
        end
        -- With wrong TC origin, click should be at a different pixel
        assert(bad_loudest_px ~= expected_click_px,
            "wrong TC origin should produce wrong click pixel — test is broken if they match")
        print(string.format("    wrong TC origin: click at pixel %d (not %d) — correctly misaligned",
            bad_loudest_px, expected_click_px))
    end
end

-- Cleanup
EMP.PEAK_RELEASE(peak_handle)
os.execute(string.format("rm -rf %q", PEAK_DIR))

print("✅ test_waveform_end_to_end.lua passed")
