--- Waveform color derivation — darkens a hex color by 40% for waveform display.
--- @module waveform_color
local M = {}

--- Derive waveform color from clip body color.
--- Multiplies each RGB component by 0.6 (40% darker).
--- @param hex_color string "#rrggbb" format
--- @return string darkened "#rrggbb"
function M.derive(hex_color)
    assert(type(hex_color) == "string" and #hex_color == 7 and hex_color:sub(1, 1) == "#",
        "waveform_color.derive: expected #rrggbb, got " .. tostring(hex_color))
    local r = tonumber(hex_color:sub(2, 3), 16)
    local g = tonumber(hex_color:sub(4, 5), 16)
    local b = tonumber(hex_color:sub(6, 7), 16)
    assert(r and g and b, "waveform_color.derive: invalid hex digits in " .. hex_color)
    r = math.min(255, math.max(0, math.floor(r * 0.6 + 0.5)))
    g = math.min(255, math.max(0, math.floor(g * 0.6 + 0.5)))
    b = math.min(255, math.max(0, math.floor(b * 0.6 + 0.5)))
    return string.format("#%02x%02x%02x", r, g, b)
end

return M
