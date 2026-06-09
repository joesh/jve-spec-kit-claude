#!/usr/bin/env luajit

-- Unit tests for prproj tick conversion functions.
-- No C++ bindings needed — pure math.

require('test_env')

local prproj = require("importers.prproj_importer")

local TICKS = prproj.TICKS_PER_SECOND
assert(TICKS == 254016000000, "TICKS_PER_SECOND should be 254016000000")

----------------------------------------------------------------------
-- ticks_per_frame_to_fps
----------------------------------------------------------------------
print("\n--- ticks_per_frame_to_fps ---")

-- 25fps
local fps_25 = prproj.ticks_per_frame_to_fps(10160640000)
assert(math.abs(fps_25 - 25) < 0.001,
    string.format("10160640000 ticks/frame should be 25fps (got %.6f)", fps_25))
print("✓ 25fps: " .. fps_25)

-- 24fps
local fps_24 = prproj.ticks_per_frame_to_fps(10584000000)
assert(math.abs(fps_24 - 24) < 0.001,
    string.format("10584000000 ticks/frame should be 24fps (got %.6f)", fps_24))
print("✓ 24fps: " .. fps_24)

-- 30fps
local fps_30 = prproj.ticks_per_frame_to_fps(8467200000)
assert(math.abs(fps_30 - 30) < 0.001,
    string.format("8467200000 ticks/frame should be 30fps (got %.6f)", fps_30))
print("✓ 30fps: " .. fps_30)

-- 48kHz audio
local fps_48k = prproj.ticks_per_frame_to_fps(5292000)
assert(math.abs(fps_48k - 48000) < 1,
    string.format("5292000 ticks/sample should be 48000Hz (got %.1f)", fps_48k))
print("✓ 48kHz: " .. fps_48k)

-- 23.976fps (24000/1001)
local fps_23976 = prproj.ticks_per_frame_to_fps(10594584000)
assert(math.abs(fps_23976 - 23.976) < 0.001,
    string.format("10594584000 ticks/frame should be ~23.976fps (got %.6f)", fps_23976))
print("✓ 23.976fps: " .. fps_23976)

----------------------------------------------------------------------
-- ticks_to_frames — exact division cases
----------------------------------------------------------------------
print("\n--- ticks_to_frames (exact) ---")

-- 1 second at 25fps = 25 frames
local one_sec_25 = prproj.ticks_to_frames(TICKS, 10160640000)
assert(one_sec_25 == 25, string.format("1 second at 25fps = 25 frames (got %d)", one_sec_25))
print("✓ 1s @ 25fps = " .. one_sec_25 .. " frames")

-- 1 hour at 25fps = 90000 frames
local one_hour_25 = prproj.ticks_to_frames(TICKS * 3600, 10160640000)
assert(one_hour_25 == 90000, string.format("1 hour @ 25fps = 90000 (got %d)", one_hour_25))
print("✓ 1h @ 25fps = " .. one_hour_25 .. " frames")

-- 1 second at 48kHz = 48000 samples
local one_sec_48k = prproj.ticks_to_frames(TICKS, 5292000)
assert(one_sec_48k == 48000, string.format("1s @ 48kHz = 48000 (got %d)", one_sec_48k))
print("✓ 1s @ 48kHz = " .. one_sec_48k .. " samples")

-- 0 ticks = 0 frames
local zero = prproj.ticks_to_frames(0, 10160640000)
assert(zero == 0, "0 ticks = 0 frames")
print("✓ 0 ticks = 0")

----------------------------------------------------------------------
-- ticks_to_frames — real values from fixture
----------------------------------------------------------------------
print("\n--- ticks_to_frames (fixture values) ---")

-- From fixture: End=2540160000000 at 25fps video ticks_per_frame=10160640000
-- 2540160000000 / 10160640000 = 250 frames
local fixture_end = prproj.ticks_to_frames(2540160000000, 10160640000)
assert(fixture_end == 250, string.format("fixture End = 250 frames (got %d)", fixture_end))
print("✓ fixture End 2540160000000 = " .. fixture_end .. " frames")

-- InPoint=477550080000 at 25fps
-- 477550080000 / 10160640000 = 47.0 frames
local fixture_in = prproj.ticks_to_frames(477550080000, 10160640000)
assert(fixture_in == 47, string.format("fixture InPoint = 47 frames (got %d)", fixture_in))
print("✓ fixture InPoint 477550080000 = " .. fixture_in .. " frames")

-- ZeroPoint=911917440000000 at 25fps
-- 911917440000000 / 10160640000 = 89750 frames
local fixture_zp = prproj.ticks_to_frames(911917440000000, 10160640000)
assert(fixture_zp == 89750, string.format("fixture ZeroPoint = 89750 frames (got %d)", fixture_zp))
print("✓ fixture ZeroPoint 911917440000000 = " .. fixture_zp .. " frames (01:00:00:00 - 250 = 89750)")

----------------------------------------------------------------------
-- ticks_to_frames — assert on bad input
----------------------------------------------------------------------
print("\n--- ticks_to_frames error paths ---")

local ok1, err1 = pcall(prproj.ticks_to_frames, "abc", 10160640000)
assert(not ok1, "should reject non-number ticks")
print("✓ rejects non-number ticks: " .. tostring(err1):sub(1, 60))

local ok2, err2 = pcall(prproj.ticks_to_frames, 1000, 0)
assert(not ok2, "should reject zero ticks_per_frame")
print("✓ rejects zero ticks_per_frame: " .. tostring(err2):sub(1, 60))

local ok3 = pcall(prproj.ticks_to_frames, 1000, -1)
assert(not ok3, "should reject negative ticks_per_frame")
print("✓ rejects negative ticks_per_frame")

print("✅ test_prproj_ticks.lua passed")
