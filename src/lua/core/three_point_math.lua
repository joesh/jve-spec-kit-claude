--- three_point_math — 3-point edit arithmetic (Feature 015, FR-036/037/038).
---
--- Given any 3 of (src_in, src_out, rec_in, rec_out), computes the 4th.
--- Rate conversion is exact-integer: asserts no sub-frame remainder.
---
--- @file three_point_math.lua

local M = {}

--- Convert a duration from src_fps units to rec_fps units.
--- Asserts exact divisibility — no sub-frame fragments allowed.
local function convert_duration(dur, src_fps, rec_fps)
    local numerator   = dur * rec_fps[1] * src_fps[2]
    local denominator = src_fps[1] * rec_fps[2]
    assert(numerator % denominator == 0, string.format(
        "three_point_math: sub-frame remainder in rate conversion "
        .. "(dur=%d, src=%d/%d, rec=%d/%d) — %d / %d is not exact",
        dur, src_fps[1], src_fps[2], rec_fps[1], rec_fps[2], numerator, denominator))
    return math.floor(numerator / denominator)
end

--- Compute the missing mark given exactly 3 of 4 marks.
---
--- @param marks   table  { src_in, src_out, rec_in, rec_out } with exactly one nil
--- @param src_fps table  { numerator, denominator }
--- @param rec_fps table  { numerator, denominator }
--- @return table  All four marks plus computed_key naming the field that was derived.
function M.compute(marks, src_fps, rec_fps)
    assert(type(marks)   == "table", "three_point_math.compute: marks must be a table")
    assert(type(src_fps) == "table" and src_fps[1] and src_fps[2],
        "three_point_math.compute: src_fps must be {numerator, denominator}")
    assert(type(rec_fps) == "table" and rec_fps[1] and rec_fps[2],
        "three_point_math.compute: rec_fps must be {numerator, denominator}")

    local si, so, ri, ro = marks.src_in, marks.src_out, marks.rec_in, marks.rec_out
    local nil_count = (si == nil and 1 or 0) + (so == nil and 1 or 0)
                    + (ri == nil and 1 or 0) + (ro == nil and 1 or 0)

    assert(nil_count == 1, string.format(
        "three_point_math.compute: exactly 3 marks required (exactly 1 nil); got %d nils",
        nil_count))

    if si ~= nil and so ~= nil then
        assert(so > si, string.format(
            "three_point_math.compute: src range must be positive; src_in=%d src_out=%d", si, so))
    end
    if ri ~= nil and ro ~= nil then
        assert(ro > ri, string.format(
            "three_point_math.compute: rec range must be positive; rec_in=%d rec_out=%d", ri, ro))
    end

    local result = { src_in = si, src_out = so, rec_in = ri, rec_out = ro }

    if ro == nil then
        result.rec_out      = ri + convert_duration(so - si, src_fps, rec_fps)
        result.computed_key = "rec_out"

    elseif ri == nil then
        result.rec_in       = ro - convert_duration(so - si, src_fps, rec_fps)
        result.computed_key = "rec_in"

    elseif so == nil then
        result.src_out      = si + convert_duration(ro - ri, rec_fps, src_fps)
        result.computed_key = "src_out"

    else
        result.src_in       = so - convert_duration(ro - ri, rec_fps, src_fps)
        result.computed_key = "src_in"
    end

    return result
end

return M
