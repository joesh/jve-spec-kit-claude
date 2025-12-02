#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require('test_env')

local timecode = require('core.timecode')

-- Ensure formatting tolerates millisecond inputs that land on fractional frames.
local rate = {fps_numerator = 24, fps_denominator = 1}

-- 208.333... ms is 5 frames at 24fps (since 1 frame ≈ 41.6667 ms)
local label = timecode.format_ruler_label(208.33333333333, rate, "frames")
assert(label ~= nil and label ~= "", "format_ruler_label should produce a label for ms input")

-- Also verify a smaller ms value doesn't throw
local label2 = timecode.format_ruler_label(41.666666666667, rate, "frames")
assert(label2 ~= nil and label2 ~= "", "format_ruler_label should handle sub-second ms input")

print("✅ timecode.format_ruler_label handles millisecond inputs on fractional frames")
