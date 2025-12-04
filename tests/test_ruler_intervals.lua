#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require('test_env')

local frame_utils = require('core.frame_utils')

local rate24 = {fps_numerator = 24, fps_denominator = 1}

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s (expected %s, got %s)", msg or "assert_eq failed", tostring(b), tostring(a)))
    end
end

-- A small target should pick a handful of frames (nice bucket)
do
    local viewport_frames = 40 -- ~1.67s (keeps frame buckets eligible)
    local pixels_per_frame = 50 -- target_frames ~= 2
    local interval_frames, hint, val = frame_utils.get_ruler_interval(viewport_frames, rate24, 100, pixels_per_frame)
    -- 24fps, target_frames ~2 → should snap to 2 frames
    assert(hint == "frames", "expected frame hint for tiny intervals")
    assert_eq(val, 2, "expected 2-frame ruler interval")
    assert_eq(interval_frames, 2, "interval_frames should equal ~2 frames")
end

-- A mid-range target should pick a round seconds bucket
do
    local viewport_frames = 240 -- 10s
    local pixels_per_frame = 5   -- width ~1200px
    local interval_frames, hint, val = frame_utils.get_ruler_interval(viewport_frames, rate24, 100, pixels_per_frame)
    assert(hint == "seconds", "expected seconds hint for mid intervals")
    assert_eq(interval_frames, 24, "seconds bucket should be 1s (24 frames)")
end

-- A ~4s viewport at ~1100px wide should prefer whole seconds over 0.5s buckets
do
    local viewport_ms = 4000 -- used only to derive pixels_per_frame
    local width_px = 1100
    local pixels_per_ms = width_px / viewport_ms
    local pixels_per_frame = pixels_per_ms * (1000/24)
    local interval_frames, hint, val = frame_utils.get_ruler_interval(24 * 4, rate24, 100, pixels_per_frame)
    assert(hint == "seconds", "expected seconds hint for mid zoom")
    assert(math.abs(val - 1.0) < 0.01, "should round up to 1-second ticks instead of half-seconds")
end

-- A ~9s viewport at ~1200px wide should pick whole seconds (not odd frame buckets)
do
    local viewport_ms = 9000
    local width_px = 1200
    local pixels_per_ms = width_px / viewport_ms
    local pixels_per_frame = pixels_per_ms * (1000/24)
    local interval_frames, hint, val = frame_utils.get_ruler_interval(24 * 9, rate24, 100, pixels_per_frame)
    assert(hint == "seconds", "expected seconds hint for ~10s viewport")
    assert(math.abs(val - 1.0) < 0.01, "should prefer 1-second ruler steps at this zoom")
end

-- A ~3s viewport at ~1200px should still prefer whole seconds (not 12-frame ticks)
do
    local viewport_ms = 3000
    local width_px = 1200
    local pixels_per_ms = width_px / viewport_ms
    local pixels_per_frame = pixels_per_ms * (1000/24)
    local interval_frames, hint, val = frame_utils.get_ruler_interval(24 * 3, rate24, 100, pixels_per_frame)
    assert(hint == "seconds", "expected seconds hint for ~3s viewport")
    assert(math.abs(val - 1.0) < 0.01, "should elevate to 1-second ticks instead of half-seconds")
end

-- Very large targets should yield minute buckets
do
    local interval_frames, hint, val = frame_utils.get_ruler_interval(24 * 600, rate24, 500000, 1)
    assert(hint == "minutes", "expected minutes hint for huge intervals")
    assert(val > 0.5, "minute interval value should be reasonable")
end

print("✅ ruler intervals prefer nice 1/2/5 buckets")
