--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~18 LOC
-- Volatility: unknown
--
-- @file color_utils.lua
local M = {}

local function assert_hex_color(hex)
    assert(type(hex) == "string", "color_utils: expected hex string color")
    assert(hex:match("^#%x%x%x%x%x%x$"), "color_utils: expected '#RRGGBB' hex color, got " .. tostring(hex))
end

function M.dim_hex(hex, factor)
    assert_hex_color(hex)
    assert(type(factor) == "number", "color_utils.dim_hex: expected numeric factor")
    assert(factor >= 0 and factor <= 1, "color_utils.dim_hex: factor must be in [0, 1]")

    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local b = tonumber(hex:sub(6, 7), 16)

    r = math.floor(r * factor + 0.5)
    g = math.floor(g * factor + 0.5)
    b = math.floor(b * factor + 0.5)

    return string.format("#%02x%02x%02x", r, g, b)
end

return M

