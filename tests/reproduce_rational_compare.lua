#!/usr/bin/env luajit
-- Reproduction script for Rational comparisons

package.path = package.path .. ";src/lua/?.lua"
local Rational = require("core.rational")

print("--- Rational Comparison Reproduction ---")

local r = Rational.new(10, 30, 1)
local n = 100
local t = {frames=10, fps_numerator=30, fps_denominator=1} -- Plain table

local function try_comp(desc, a, b)
    print("Testing: " .. desc)
    local ok, err = pcall(function() return a < b end)
    if ok then
        print("  OK")
    else
        print("  FAILED: " .. tostring(err))
    end
end

try_comp("Rational < Rational", r, r)
try_comp("Rational < Number", r, n)
try_comp("Number < Rational", n, r)

-- These are expected to fail, but let's see the error message
try_comp("Rational < PlainTable", r, t)
try_comp("PlainTable < Rational", t, r)
try_comp("Number < PlainTable", n, t)
try_comp("PlainTable < Number", t, n)

-- Mocking the exact clip_mutator scenario?
-- clip_start (Rational) < start_value (Rational)
-- If metatables are lost?

local _ = {frames=10, fps_numerator=30, fps_denominator=1}  -- r_nometa for manual testing
-- simulate lost metatable
-- but row.start_value printed as "Rational(...)" in log, so it HAD metatable.

-- What if Rational module was reloaded and metatable identity changed?
-- LuaJIT `package.loaded` prevents reload.

-- What if `val_max` or `val_min` returned a number?
-- `clip_mutator` uses `val_max` for `overlap_start`.
-- But line 216 compares `clip_start` (raw from row) < `start_value` (raw from params).

-- Maybe `start_value` passed to `resolve_occlusions` is NOT Rational?
-- In `Overwrite`: `overwrite_time_rat = hydrate(overwrite_time_raw)`.
-- `hydrate` returns `Rational.new(...)`.
-- So `start_value` is Rational.

-- Wait, `resolve_occlusions` takes `params`.
-- `params.start_value`.
-- `local start_value = params.timeline_start or params.start_value`.

-- If `Overwrite` passed `timeline_start = overwrite_time_rat` (Rational).

-- I'll check the output of this script.
