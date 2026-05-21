--- three_point_math — 3-point edit arithmetic (Feature 015, FR-036/037/038).
---
--- Given any 3 of (src_in, src_out, rec_in, rec_out), computes the 4th.
--- Rate conversion is exact-integer: asserts no sub-frame remainder.
---
--- @file three_point_math.lua

local M = {}

--- Convert a duration from src_fps units to rec_fps units.
--- mode="strict" (default): asserts exact divisibility (used by committed
--- 3-point edits — Insert/Overwrite must land on integer frames).
--- mode="floor": floors the result and returns (frames, exact_bool) so
--- callers can render a transient display value (e.g. ghost marks) for
--- cross-rate cases that don't divide exactly.
local function convert_duration(dur, src_fps, rec_fps, mode)
    local numerator   = dur * rec_fps[1] * src_fps[2]
    local denominator = src_fps[1] * rec_fps[2]
    local exact = (numerator % denominator == 0)
    if mode ~= "floor" then
        assert(exact, string.format(
            "three_point_math: sub-frame remainder in rate conversion "
            .. "(dur=%d, src=%d/%d, rec=%d/%d) — %d / %d is not exact",
            dur, src_fps[1], src_fps[2], rec_fps[1], rec_fps[2], numerator, denominator))
    end
    return math.floor(numerator / denominator), exact
end

--- Compute the missing mark given exactly 3 of 4 marks.
---
--- @param marks   table  { src_in, src_out, rec_in, rec_out } with exactly one nil
--- @param src_fps table  { numerator, denominator }
--- @param rec_fps table  { numerator, denominator }
--- @param opts    table|nil  { rounding = "strict"|"floor" }; "strict" (default)
---                asserts integer divisibility. "floor" floors the converted
---                duration and sets result.exact=false when a remainder was
---                dropped. Use "floor" ONLY for transient UI display (e.g.
---                ghost marks); committed edits must stay "strict".
--- @return table  All four marks plus computed_key + exact (bool).
function M.compute(marks, src_fps, rec_fps, opts)
    assert(type(marks)   == "table", "three_point_math.compute: marks must be a table")
    assert(type(src_fps) == "table" and src_fps[1] and src_fps[2],
        "three_point_math.compute: src_fps must be {numerator, denominator}")
    assert(type(rec_fps) == "table" and rec_fps[1] and rec_fps[2],
        "three_point_math.compute: rec_fps must be {numerator, denominator}")
    local mode = (opts and opts.rounding) or "strict"
    assert(mode == "strict" or mode == "floor",
        "three_point_math.compute: opts.rounding must be 'strict' or 'floor'")

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
    local converted, exact

    if ro == nil then
        converted, exact   = convert_duration(so - si, src_fps, rec_fps, mode)
        result.rec_out     = ri + converted
        result.computed_key = "rec_out"

    elseif ri == nil then
        converted, exact   = convert_duration(so - si, src_fps, rec_fps, mode)
        result.rec_in      = ro - converted
        result.computed_key = "rec_in"

    elseif so == nil then
        converted, exact   = convert_duration(ro - ri, rec_fps, src_fps, mode)
        result.src_out     = si + converted
        result.computed_key = "src_out"

    else
        converted, exact   = convert_duration(ro - ri, rec_fps, src_fps, mode)
        result.src_in      = so - converted
        result.computed_key = "src_in"
    end

    result.exact = exact
    return result
end

return M
