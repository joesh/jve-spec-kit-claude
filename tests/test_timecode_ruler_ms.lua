#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require('test_env')

local timecode = require('core.timecode')
local Rational = require('core.rational')

local rate = {fps_numerator = 24, fps_denominator = 1}

-- Rational input on fractional frames (5 frames @24fps)
local label = timecode.format_ruler_label(Rational.new(5, 24, 1), rate)
assert(label ~= nil and label ~= "", "format_ruler_label should produce a label for Rational input")

-- Numeric frames input
local label2 = timecode.format_ruler_label(5, rate)
assert(label2 ~= nil and label2 ~= "", "format_ruler_label should handle numeric frame input")

-- Fractional numeric inputs should be rejected
local ok = pcall(function() return timecode.format_ruler_label(41.6666, rate) end)
assert(not ok, "format_ruler_label should reject fractional numeric inputs")

print("✅ timecode.format_ruler_label handles frame-based inputs")
