require("test_env")
local pc = require("core.media.peak_constants")

print("--- test_peak_coords.lua ---")

-- Peak coordinate mapping: given source_in, source_out (in source samples),
-- and a pixel width, compute which peak bins to read and at which mipmap level.
--
-- This tests the mapping logic that peak_cache.get_visible_peaks will use.

--- Map a source sample range to peak bin range at the appropriate mipmap level.
--- @param source_in number start sample (absolute, in source samples)
--- @param source_out number end sample (exclusive, in source samples)
--- @param pixel_width number number of screen pixels for the clip
--- @return number level (1-based mipmap level)
--- @return number start_bin (0-based, inclusive)
--- @return number end_bin (0-based, exclusive)
--- @return number bins_count
local function map_source_to_peaks(source_in, source_out, pixel_width)
    assert(source_out > source_in, "source_out must be > source_in")
    assert(pixel_width > 0, "pixel_width must be > 0")

    local total_source_samples = source_out - source_in
    local samples_per_pixel = total_source_samples / pixel_width
    local level = pc.select_level(samples_per_pixel)
    local spp = pc.SAMPLES_PER_LEVEL[level]

    local start_bin = math.floor(source_in / spp)
    local end_bin = math.ceil(source_out / spp)
    local bins_count = end_bin - start_bin

    return level, start_bin, end_bin, bins_count
end

-- Non-trivial source_in: 188160 samples (typical audio offset)
-- source_out: 188160 + 48000*10 = 188160 + 480000 = 668160
-- pixel_width: 500
-- samples_per_pixel: 480000/500 = 960
-- select_level(960): 512 <= 960, 1024 > 960 → level 2 (spp=512)
-- start_bin: floor(188160/512) = floor(367.5) = 367
-- end_bin: ceil(668160/512) = ceil(1304.6875) = 1305
-- bins_count: 1305 - 367 = 938
local level, start_bin, end_bin, bins_count = map_source_to_peaks(188160, 668160, 500)
assert(level == 2, "level expected 2 got " .. level)
assert(start_bin == 367, "start_bin expected 367 got " .. start_bin)
assert(end_bin == 1305, "end_bin expected 1305 got " .. end_bin)
assert(bins_count == 938, "bins_count expected 938 got " .. bins_count)
print("  non-trivial offset OK")

-- Trim: shorten source_out (tail trim)
-- source_in stays 188160, source_out becomes 428160 (5 seconds instead of 10)
-- pixel_width: 250 (half the original clip width)
-- samples_per_pixel: 240000/250 = 960 → same level 2 (spp=512)
-- start_bin: floor(188160/512) = 367 (unchanged — same source_in)
-- end_bin: ceil(428160/512) = ceil(836.25) = 837
-- bins_count: 837 - 367 = 470
local level2, start_bin2, end_bin2, bins_count2 = map_source_to_peaks(188160, 428160, 250)
assert(level2 == 2, "trim: level expected 2 got " .. level2)
assert(start_bin2 == 367, "trim: start_bin expected 367 got " .. start_bin2)
assert(end_bin2 == 837, "trim: end_bin expected 837 got " .. end_bin2)
assert(bins_count2 == 470, "trim: bins_count expected 470 got " .. bins_count2)
print("  tail trim OK — same start_bin, different end_bin")

-- Slip: change source_in (shift both in and out by 24000 samples = 0.5sec)
-- source_in: 212160, source_out: 692160
-- pixel_width: 500
-- samples_per_pixel: 480000/500 = 960 → level 2 (spp=512)
-- start_bin: floor(212160/512) = floor(414.375) = 414
-- end_bin: ceil(692160/512) = ceil(1351.875) = 1352
-- bins_count: 1352 - 414 = 938 (same count — just offset shifted)
local level3, start_bin3, end_bin3, bins_count3 = map_source_to_peaks(212160, 692160, 500)
assert(level3 == 2, "slip: level expected 2 got " .. level3)
assert(start_bin3 == 414, "slip: start_bin expected 414 got " .. start_bin3)
assert(end_bin3 == 1352, "slip: end_bin expected 1352 got " .. end_bin3)
assert(bins_count3 == 938, "slip: bins_count expected 938 got " .. bins_count3)
print("  slip OK — offset shifted, same bin count")

-- Speed != 1.0: double speed means half the source range maps to same pixel width
-- source_in: 188160, clip covers 480000 source samples at 2x speed
-- Effective source range shown = 480000 * 2 = 960000
-- source_out: 188160 + 960000 = 1148160
-- pixel_width: 500
-- samples_per_pixel: 960000/500 = 1920
-- select_level(1920): 1024 <= 1920, 2048 > 1920 → level 3 (spp=1024)
-- start_bin: floor(188160/1024) = floor(183.75) = 183
-- end_bin: ceil(1148160/1024) = ceil(1121.25) = 1122
-- bins_count: 1122 - 183 = 939
local level4, start_bin4, end_bin4, bins_count4 = map_source_to_peaks(188160, 1148160, 500)
assert(level4 == 3, "speed: level expected 3 got " .. level4)
assert(start_bin4 == 183, "speed: start_bin expected 183 got " .. start_bin4)
assert(end_bin4 == 1122, "speed: end_bin expected 1122 got " .. end_bin4)
assert(bins_count4 == 939, "speed: bins_count expected 939 got " .. bins_count4)
print("  speed 2x OK — coarser mipmap level")

-- Zoomed in heavily: 100 samples visible across 500 pixels
-- source_in: 188160, source_out: 188260
-- samples_per_pixel: 100/500 = 0.2 → but select_level needs > 0
-- This means we're zoomed in beyond individual samples
-- select_level(0.2): all levels > 0.2, fall to level 1
local level5, start_bin5, _, _ = map_source_to_peaks(188160, 188260, 500)
assert(level5 == 1, "zoomed in: level expected 1 got " .. level5)
assert(start_bin5 == 735, "zoomed in: start_bin expected 735 got " .. start_bin5)
print("  extreme zoom-in OK")

-- Very wide clip: 48000*3600 samples (1 hour) across 1920 pixels
-- samples_per_pixel: 172800000/1920 = 90000
-- select_level(90000): 2048 <= 90000 → level 4
local level6, _, _, _ = map_source_to_peaks(0, 48000 * 3600, 1920)
assert(level6 == 4, "wide clip: level expected 4 got " .. level6)
print("  1-hour clip OK — coarsest level")

print("✅ test_peak_coords.lua passed")
