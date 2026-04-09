--- Peak file format constants shared between Lua tests and Lua-side logic.
--- C++ has its own constants in emp_peak_file.h.
---
--- @module peak_constants
local M = {}

M.PEAK_MAGIC = "JVPK"
M.PEAK_VERSION = 1
M.BASE_SAMPLES_PER_PEAK = 256
M.MIPMAP_LEVELS = 4
M.HEADER_SIZE = 64
M.SAMPLES_PER_LEVEL = {256, 512, 1024, 2048}

--- Compute bin count at a given mipmap level for a total sample count.
--- @param total_samples number total audio samples in source file
--- @param level number 1-based mipmap level index (1 = base 256 spp)
--- @return number bin count at that level
function M.bins_at_level(total_samples, level)
    assert(type(total_samples) == "number" and total_samples >= 0,
        "peak_constants.bins_at_level: total_samples must be >= 0, got " .. tostring(total_samples))
    assert(type(level) == "number" and level >= 1 and level <= M.MIPMAP_LEVELS,
        "peak_constants.bins_at_level: level must be 1-" .. M.MIPMAP_LEVELS .. ", got " .. tostring(level))
    if total_samples == 0 then return 0 end
    local spp = M.SAMPLES_PER_LEVEL[level]
    return math.ceil(total_samples / spp)
end

--- Select the best mipmap level for a given samples-per-pixel ratio.
--- Picks the coarsest level where samples_per_peak <= samples_per_pixel.
--- @param samples_per_pixel number how many source samples span one screen pixel
--- @return number 1-based mipmap level index
function M.select_level(samples_per_pixel)
    assert(type(samples_per_pixel) == "number" and samples_per_pixel > 0,
        "peak_constants.select_level: samples_per_pixel must be > 0, got " .. tostring(samples_per_pixel))
    for i = M.MIPMAP_LEVELS, 1, -1 do
        if M.SAMPLES_PER_LEVEL[i] <= samples_per_pixel then
            return i
        end
    end
    return 1
end

return M
