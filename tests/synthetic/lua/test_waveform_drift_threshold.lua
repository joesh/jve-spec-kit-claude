require("test_env")
local peak_constants = require("core.media.peak_constants")

local function check(desc, cond)
    if not cond then error("FAIL: " .. desc) end
    print("  OK: " .. desc)
end

-- ============================================================
-- Regression: waveform TC mismatch threshold must scale with mipmap level
--
-- Bug: Hardcoded MAX_BIN_DRIFT=512 was tighter than the bin size at
-- mipmap levels 3-4 (1024/2048 spp). PEAK_QUERY snaps to bin boundaries,
-- so drift of up to spp per edge is legitimate. The fixed threshold
-- uses the selected mipmap level's samples_per_peak.
-- ============================================================

print("\n--- waveform drift: select_level picks correct level ---")

-- At 256 spp zoom, level 1 (threshold 256 — old 512 was fine)
local level_256 = peak_constants.select_level(256)
check("256 spp selects level 1", level_256 == 1)
check("level 1 threshold is 256",
    peak_constants.SAMPLES_PER_LEVEL[level_256] == 256)

-- At 1024 spp zoom, level 3 (threshold 1024 — old 512 was wrong)
local level_1024 = peak_constants.select_level(1024)
check("1024 spp selects level 3", level_1024 == 3)
check("level 3 threshold is 1024",
    peak_constants.SAMPLES_PER_LEVEL[level_1024] == 1024)

-- At 2048 spp zoom, level 4 (threshold 2048 — old 512 was wrong)
local level_2048 = peak_constants.select_level(2048)
check("2048 spp selects level 4", level_2048 == 4)
check("level 4 threshold is 2048",
    peak_constants.SAMPLES_PER_LEVEL[level_2048] == 2048)

print("\n--- waveform drift: real TSO drift values are legitimate ---")

-- Actual drift values from the TSO that triggered false warnings.
-- All are within the bin size of their mipmap level.
local real_drifts = {
    { start_d = 640, end_d = 1024, spp = 1024 },
    { start_d = 1024, end_d = 256, spp = 1024 },
    { start_d = 0, end_d = 965, spp = 1024 },
    { start_d = 768, end_d = 256, spp = 1024 },
    { start_d = 0, end_d = 667, spp = 1024 },
}

for i, d in ipairs(real_drifts) do
    local level = peak_constants.select_level(d.spp)
    local threshold = peak_constants.SAMPLES_PER_LEVEL[level]
    local is_legit = d.start_d <= threshold and d.end_d <= threshold
    check(string.format("TSO drift #%d [%d,%d] at spp=%d: within threshold %d",
        i, d.start_d, d.end_d, d.spp, threshold),
        is_legit == true)
end

print("\n✅ test_waveform_drift_threshold.lua passed")
