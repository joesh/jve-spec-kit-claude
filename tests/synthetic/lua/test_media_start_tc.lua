#!/usr/bin/env luajit
--- Test Media:get_start_tc() accessor
require("test_env")

print("=== test_media_start_tc.lua ===")

local Media = require("models.media")
local json = require("dkjson")

---------------------------------------------------------------------------------
-- Test 1: Media with start_tc in metadata
---------------------------------------------------------------------------------
print("\n--- Test 1: get_start_tc with valid metadata ---")

local media = Media.create({
    file_path = "/test/video.mov",
    name = "video.mov",
    duration_frames = 100,
    fps_numerator = 25,
    fps_denominator = 1,
    metadata = json.encode({start_tc_value = 89750, start_tc_rate = 25}),
})

local value, rate = media:get_start_tc()
assert(value == 89750, string.format("expected value=89750, got %s", tostring(value)))
assert(rate == 25, string.format("expected rate=25, got %s", tostring(rate)))
print("  ✓ get_start_tc returns (89750, 25)")

---------------------------------------------------------------------------------
-- Test 2: Media with empty metadata — TC unknown (no file to extract from)
---------------------------------------------------------------------------------
print("\n--- Test 2: get_start_tc with empty metadata ---")

local media_empty = Media.create({
    file_path = "/test/empty.mov",
    name = "empty.mov",
    duration_frames = 50,
    fps_numerator = 24,
    fps_denominator = 1,
    metadata = "{}",
})

local v2, r2 = media_empty:get_start_tc()
assert(v2 == nil, string.format("expected nil (TC unknown, no file), got %s", tostring(v2)))
assert(r2 == nil, string.format("expected nil rate, got %s", tostring(r2)))
print("  ✓ get_start_tc returns (nil, nil) for empty metadata (file offline)")

---------------------------------------------------------------------------------
-- Test 3: Media with no metadata field — TC unknown
---------------------------------------------------------------------------------
print("\n--- Test 3: get_start_tc with default metadata ---")

local media_default = Media.create({
    file_path = "/test/default.mov",
    name = "default.mov",
    duration_frames = 50,
    fps_numerator = 25,
    fps_denominator = 1,
})

local v3, r3 = media_default:get_start_tc()
assert(v3 == nil, string.format("expected nil (TC unknown), got %s", tostring(v3)))
assert(r3 == nil, string.format("expected nil rate, got %s", tostring(r3)))
print("  ✓ get_start_tc returns (nil, nil) for default metadata")

---------------------------------------------------------------------------------
-- Test 4: Media with start_tc_value = 0 (valid, means TC 00:00:00:00)
---------------------------------------------------------------------------------
print("\n--- Test 4: get_start_tc with zero value ---")

local media_zero = Media.create({
    file_path = "/test/zero.mov",
    name = "zero.mov",
    duration_frames = 100,
    fps_numerator = 25,
    fps_denominator = 1,
    metadata = json.encode({start_tc_value = 0, start_tc_rate = 25}),
})

local v4, r4 = media_zero:get_start_tc()
assert(v4 == 0, string.format("expected value=0, got %s", tostring(v4)))
assert(r4 == 25, string.format("expected rate=25, got %s", tostring(r4)))
print("  ✓ get_start_tc returns (0, 25) for zero TC")

---------------------------------------------------------------------------------
-- Test 5: Media with metadata as pre-parsed table
---------------------------------------------------------------------------------
print("\n--- Test 5: get_start_tc with table metadata ---")

local media_table = Media.create({
    file_path = "/test/table.mov",
    name = "table.mov",
    duration_frames = 100,
    fps_numerator = 30000,
    fps_denominator = 1001,
})
-- Simulate metadata already parsed as table
media_table.metadata = {start_tc_value = 108000, start_tc_rate = 30}

local v5, r5 = media_table:get_start_tc()
assert(v5 == 108000, string.format("expected 108000, got %s", tostring(v5)))
assert(r5 == 30, string.format("expected 30, got %s", tostring(r5)))
print("  ✓ get_start_tc works with pre-parsed table metadata")

print("\n✅ test_media_start_tc.lua passed")
