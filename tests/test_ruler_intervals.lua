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
    local interval_ms, hint, val = frame_utils.get_ruler_interval(0, rate24, 100, 1) -- target_ms = 100
    -- 24fps → frame_ms ~= 41.67, target_frames ~2.4 → should snap to 2 frames (close, not too small)
    assert(hint == "frames", "expected frame hint for tiny intervals")
    assert_eq(val, 2, "expected 2-frame ruler interval")
    local expected_ms = (1000 / 24) * 2
    assert(math.abs(interval_ms - expected_ms) < 0.1, "interval_ms should equal ~2 frames")
end

-- A larger target should pick a round seconds bucket
do
    -- target_ms = 3500 → target_seconds ~3.5 → should snap to 5 second bucket
    local interval_ms, hint, val = frame_utils.get_ruler_interval(0, rate24, 3500, 1)
    assert(hint == "seconds", "expected seconds hint for mid intervals")
    assert(math.abs(val - 5.0) < 0.01, "seconds interval should snap to 5s")
    local expected_ms = 5000
    assert(math.abs(interval_ms - expected_ms) < 0.5, "interval_ms should match 5-second bucket")
end

-- A ~4s viewport at ~1100px wide should prefer whole seconds over 0.5s buckets
do
    local viewport_ms = 4000
    local width_px = 1100
    local pixels_per_ms = width_px / viewport_ms
    local interval_ms, hint, val = frame_utils.get_ruler_interval(viewport_ms, rate24, 100, pixels_per_ms)
    assert(hint == "seconds", "expected seconds hint for mid zoom")
    assert(math.abs(val - 1.0) < 0.01, "should round up to 1-second ticks instead of half-seconds")
end

-- A ~9s viewport at ~1200px wide should pick whole seconds (not odd frame buckets)
do
    local viewport_ms = 9000
    local width_px = 1200
    local pixels_per_ms = width_px / viewport_ms
    local interval_ms, hint, val = frame_utils.get_ruler_interval(viewport_ms, rate24, 100, pixels_per_ms)
    assert(hint == "seconds", "expected seconds hint for ~10s viewport")
    assert(math.abs(val - 1.0) < 0.01, "should prefer 1-second ruler steps at this zoom")
    local expected_ms = 1000
    assert(math.abs(interval_ms - expected_ms) < 1, "interval_ms should be ~1000ms")
end

-- A ~3s viewport at ~1200px should still prefer whole seconds (not 12-frame ticks)
do
    local viewport_ms = 3000
    local width_px = 1200
    local pixels_per_ms = width_px / viewport_ms
    local interval_ms, hint, val = frame_utils.get_ruler_interval(viewport_ms, rate24, 100, pixels_per_ms)
    assert(hint == "seconds", "expected seconds hint for ~3s viewport")
    assert(math.abs(val - 1.0) < 0.01, "should elevate to 1-second ticks instead of half-seconds")
end

-- Very large targets should yield minute buckets
do
    local interval_ms, hint, val = frame_utils.get_ruler_interval(0, rate24, 500000, 1)
    assert(hint == "minutes", "expected minutes hint for huge intervals")
    assert(val > 0.5, "minute interval value should be reasonable")
end

print("✅ ruler intervals prefer nice 1/2/5 buckets")
