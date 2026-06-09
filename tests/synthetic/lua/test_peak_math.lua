require("test_env")
local pc = require("core.media.peak_constants")

print("--- test_peak_math.lua ---")

-- Verify constants
assert(pc.PEAK_MAGIC == "JVPK", "magic mismatch")
assert(pc.PEAK_VERSION == 1, "version mismatch")
assert(pc.BASE_SAMPLES_PER_PEAK == 256, "base spp mismatch")
assert(pc.MIPMAP_LEVELS == 4, "levels mismatch")
assert(pc.HEADER_SIZE == 64, "header size mismatch")
assert(#pc.SAMPLES_PER_LEVEL == 4, "level count mismatch")
assert(pc.SAMPLES_PER_LEVEL[1] == 256, "level 1 spp")
assert(pc.SAMPLES_PER_LEVEL[2] == 512, "level 2 spp")
assert(pc.SAMPLES_PER_LEVEL[3] == 1024, "level 3 spp")
assert(pc.SAMPLES_PER_LEVEL[4] == 2048, "level 4 spp")

print("  constants OK")

-- bins_at_level: non-trivial total_samples
-- 1234567 samples at 256 spp = ceil(1234567/256) = ceil(4822.527...) = 4823
assert(pc.bins_at_level(1234567, 1) == 4823,
    "bins_at_level(1234567,1) expected 4823 got " .. pc.bins_at_level(1234567, 1))

-- 1234567 / 512 = ceil(2411.263...) = 2412
assert(pc.bins_at_level(1234567, 2) == 2412,
    "bins_at_level(1234567,2) expected 2412 got " .. pc.bins_at_level(1234567, 2))

-- 1234567 / 1024 = ceil(1205.631...) = 1206
assert(pc.bins_at_level(1234567, 3) == 1206,
    "bins_at_level(1234567,3) expected 1206 got " .. pc.bins_at_level(1234567, 3))

-- 1234567 / 2048 = ceil(602.816...) = 603
assert(pc.bins_at_level(1234567, 4) == 603,
    "bins_at_level(1234567,4) expected 603 got " .. pc.bins_at_level(1234567, 4))

print("  bins_at_level non-trivial OK")

-- bins_at_level: edge cases
assert(pc.bins_at_level(0, 1) == 0, "0 samples should give 0 bins")
assert(pc.bins_at_level(1, 1) == 1, "1 sample should give 1 bin at level 1")
assert(pc.bins_at_level(256, 1) == 1, "exactly 256 should give 1 bin")
assert(pc.bins_at_level(257, 1) == 2, "257 should give 2 bins at level 1")
assert(pc.bins_at_level(512, 1) == 2, "512 should give 2 bins at level 1")
assert(pc.bins_at_level(512, 2) == 1, "512 should give 1 bin at level 2")

-- prime number
assert(pc.bins_at_level(7919, 1) == 31,
    "bins_at_level(7919,1) expected 31 got " .. pc.bins_at_level(7919, 1))

print("  bins_at_level edge cases OK")

-- bins_at_level: invalid inputs
local ok, err = pcall(pc.bins_at_level, -1, 1)
assert(not ok, "negative samples should fail")
assert(err:find("total_samples must be >= 0"), "bad error msg: " .. tostring(err))

local ok2, err2 = pcall(pc.bins_at_level, 100, 0)
assert(not ok2, "level 0 should fail")
assert(err2:find("level must be"), "bad error msg: " .. tostring(err2))

local ok3, err3 = pcall(pc.bins_at_level, 100, 5)
assert(not ok3, "level 5 should fail")
assert(err3:find("level must be"), "bad error msg: " .. tostring(err3))

print("  bins_at_level validation OK")

-- select_level: coarsest level where spp <= samples_per_pixel
-- spp=256 at level 1, 512 at level 2, 1024 at level 3, 2048 at level 4
-- samples_per_pixel=300 → level 1 (256 <= 300, 512 > 300)
assert(pc.select_level(300) == 1,
    "select_level(300) expected 1 got " .. pc.select_level(300))

-- samples_per_pixel=512 → level 2 (512 <= 512)
assert(pc.select_level(512) == 2,
    "select_level(512) expected 2 got " .. pc.select_level(512))

-- samples_per_pixel=1000 → level 2 (512 <= 1000, 1024 > 1000)
assert(pc.select_level(1000) == 2,
    "select_level(1000) expected 2 got " .. pc.select_level(1000))

-- samples_per_pixel=1024 → level 3
assert(pc.select_level(1024) == 3,
    "select_level(1024) expected 3 got " .. pc.select_level(1024))

-- samples_per_pixel=2048 → level 4
assert(pc.select_level(2048) == 4,
    "select_level(2048) expected 4 got " .. pc.select_level(2048))

-- samples_per_pixel=100000 → level 4 (coarsest)
assert(pc.select_level(100000) == 4,
    "select_level(100000) expected 4 got " .. pc.select_level(100000))

-- samples_per_pixel=1 → level 1 (finest — zoomed in beyond base)
assert(pc.select_level(1) == 1,
    "select_level(1) expected 1 got " .. pc.select_level(1))

-- samples_per_pixel=255 → level 1 (256 > 255 so no level qualifies, fall to 1)
assert(pc.select_level(255) == 1,
    "select_level(255) expected 1 got " .. pc.select_level(255))

print("  select_level OK")

-- select_level: invalid input
local ok4, err4 = pcall(pc.select_level, 0)
assert(not ok4, "spp=0 should fail")
assert(err4:find("samples_per_pixel must be > 0"), "bad error msg: " .. tostring(err4))

local ok5, _ = pcall(pc.select_level, -10)
assert(not ok5, "negative spp should fail")

print("  select_level validation OK")

print("✅ test_peak_math.lua passed")
