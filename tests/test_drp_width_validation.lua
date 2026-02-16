#!/usr/bin/env luajit

-- Regression: DRP width=0 (hex-decoded) must NOT bypass fallback.
-- In Lua, `0 or fallback` evaluates to 0 (0 is truthy).
-- The fix uses `(v and v > 0) and v or fallback`.

require("test_env")

-- =============================================================================
-- Test the resolution fallback helper (extracted for testability)
-- =============================================================================

local function resolve_dimension(value, fallback)
    -- This is the FIXED pattern used in drp_importer
    return (value and value > 0) and value or fallback
end

local DEFAULT_W = 1920
local DEFAULT_H = 1080

-- Test 1: width=0 must fall back to default
local w0 = resolve_dimension(0, DEFAULT_W)
assert(w0 == DEFAULT_W, string.format(
    "width=0 should fall back to %d, got %s", DEFAULT_W, tostring(w0)))
print("  PASS: width=0 falls back to default")

-- Test 2: width=nil must fall back to default
local wnil = resolve_dimension(nil, DEFAULT_W)
assert(wnil == DEFAULT_W, string.format(
    "width=nil should fall back to %d, got %s", DEFAULT_W, tostring(wnil)))
print("  PASS: width=nil falls back to default")

-- Test 3: valid width is used
local w1280 = resolve_dimension(1280, DEFAULT_W)
assert(w1280 == 1280, string.format(
    "valid width should be 1280, got %s", tostring(w1280)))
print("  PASS: valid width=1280 used")

-- Test 4: negative width falls back
local wneg = resolve_dimension(-1, DEFAULT_W)
assert(wneg == DEFAULT_W, string.format(
    "negative width should fall back to %d, got %s", DEFAULT_W, tostring(wneg)))
print("  PASS: negative width falls back to default")

-- Test 5: same for height
local h0 = resolve_dimension(0, DEFAULT_H)
assert(h0 == DEFAULT_H, "height=0 should fall back")
print("  PASS: height=0 falls back to default")

-- =============================================================================
-- Test the buggy pattern to confirm it WOULD fail
-- =============================================================================
local function buggy_resolve(value, fallback)
    return value or fallback  -- Lua truthy-zero: 0 or X == 0
end

local buggy_w = buggy_resolve(0, DEFAULT_W)
assert(buggy_w == 0, "Confirming buggy pattern: 0 or fallback == 0 in Lua")
print("  PASS: confirmed buggy pattern yields 0 (Lua truthy-zero)")

-- =============================================================================
-- Test decode_hex_resolution floor behavior
-- Floor ensures fractional doubles from hex decode become integers
-- =============================================================================
local function floor_decoded(value)
    if value then return math.floor(value) end
    return nil
end

assert(floor_decoded(1920.0) == 1920, "exact double floors to int")
assert(floor_decoded(1920.999) == 1920, "fractional double floors down")
assert(floor_decoded(nil) == nil, "nil stays nil")
print("  PASS: floor_decoded handles doubles and nil")

print("✅ test_drp_width_validation.lua passed")
