require("test_env")

print("--- test_waveform_color.lua ---")

-- derive_waveform_color: takes "#rrggbb", returns "#rrggbb" at 60% brightness
-- This tests the function that will live in peak_cache or a utility module.
-- For now, define the algorithm inline so the test can run before implementation.
-- The implementation MUST match this exact algorithm.

local function parse_hex(hex)
    assert(type(hex) == "string" and #hex == 7 and hex:sub(1, 1) == "#",
        "parse_hex: expected #rrggbb, got " .. tostring(hex))
    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local b = tonumber(hex:sub(6, 7), 16)
    assert(r and g and b, "parse_hex: invalid hex digits in " .. hex)
    return r, g, b
end

local function to_hex(r, g, b)
    return string.format("#%02x%02x%02x", r, g, b)
end

local function derive_waveform_color(hex_color)
    local r, g, b = parse_hex(hex_color)
    r = math.floor(r * 0.6 + 0.5)
    g = math.floor(g * 0.6 + 0.5)
    b = math.floor(b * 0.6 + 0.5)
    return to_hex(
        math.min(255, math.max(0, r)),
        math.min(255, math.max(0, g)),
        math.min(255, math.max(0, b))
    )
end

-- Test with clip_audio color (#32986b)
-- R=0x32=50, G=0x98=152, B=0x6b=107
-- 50*0.6=30, 152*0.6=91.2→91, 107*0.6=64.2→64
-- → #1e5b40
local result1 = derive_waveform_color("#32986b")
assert(result1 == "#1e5b40",
    "clip_audio darkened: expected #1e5b40 got " .. result1)
print("  clip_audio color OK: " .. result1)

-- Test with white (#ffffff)
-- 255*0.6=153 → #999999
local result2 = derive_waveform_color("#ffffff")
assert(result2 == "#999999",
    "white darkened: expected #999999 got " .. result2)
print("  white OK: " .. result2)

-- Test with black (#000000) — stays black
local result3 = derive_waveform_color("#000000")
assert(result3 == "#000000",
    "black darkened: expected #000000 got " .. result3)
print("  black OK: " .. result3)

-- Test with clip_audio_disabled color (need to check what it is)
-- Let's use a representative disabled color — muted green (#1e4d36)
-- R=0x1e=30, G=0x4d=77, B=0x36=54
-- 30*0.6=18, 77*0.6=46.2→46, 54*0.6=32.4→32
-- → #122e20
local result4 = derive_waveform_color("#1e4d36")
assert(result4 == "#122e20",
    "disabled darkened: expected #122e20 got " .. result4)
print("  disabled color OK: " .. result4)

-- Test with bright red (#ff0000)
-- 255*0.6=153, 0*0.6=0, 0*0.6=0 → #990000
local result5 = derive_waveform_color("#ff0000")
assert(result5 == "#990000",
    "red darkened: expected #990000 got " .. result5)
print("  red OK: " .. result5)

-- Test with clip_video color (#548bb5) — just to verify math on a different value
-- R=0x54=84, G=0x8b=139, B=0xb5=181
-- 84*0.6=50.4→50, 139*0.6=83.4→83, 181*0.6=108.6→109
-- → #32536d
local result6 = derive_waveform_color("#548bb5")
assert(result6 == "#32536d",
    "video color darkened: expected #32536d got " .. result6)
print("  video color OK: " .. result6)

-- Validation: bad input
local ok, _ = pcall(derive_waveform_color, "not a color")
assert(not ok, "bad input should fail")
print("  validation OK")

print("✅ test_waveform_color.lua passed")
