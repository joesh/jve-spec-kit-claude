#!/usr/bin/env luajit

-- DRP start timecode extraction from MediaExtents on Sm2Sequence.
-- Test DRP has 3 timelines: "33" (00:00:33:00), "44" (00:44:00:00), "23hr" (23:00:00:00).

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local drp = require("importers.drp_importer")
-- Resolve path relative to script location (--test mode runs from project root)
local script_dir = debug.getinfo(1, "S").source:match("@(.*/)")
local DRP_PATH = (script_dir or "tests/") .. "fixtures/resolve/start_time_decoder.drp"

-- =========================================================================
-- Test 1: parse_drp_file extracts start_tc_seconds from MediaExtents
-- =========================================================================
local result = drp.parse_drp_file(DRP_PATH)
assert(result, "parse_drp_file should succeed")
assert(result.timelines and #result.timelines > 0,
    "should have timelines, got " .. tostring(result.timelines and #result.timelines))

-- Build name→timeline map
local by_name = {}
for _, tl in ipairs(result.timelines) do
    by_name[tl.name] = tl
end

-- Timeline "33": start TC 00:00:33:00 = 33 seconds
local tl33 = by_name["33"]
assert(tl33, "timeline '33' not found in parse result")
assert(tl33.start_tc_seconds,
    "timeline '33' should have start_tc_seconds, got nil")
assert(math.abs(tl33.start_tc_seconds - 33.0) < 0.01,
    string.format("timeline '33': expected 33.0s, got %s", tostring(tl33.start_tc_seconds)))
print("  ✓ Timeline '33': start_tc_seconds = 33.0")

-- Timeline "44": start TC 00:44:00:00 = 2640 seconds
local tl44 = by_name["44"]
assert(tl44, "timeline '44' not found in parse result")
assert(tl44.start_tc_seconds,
    "timeline '44' should have start_tc_seconds, got nil")
assert(math.abs(tl44.start_tc_seconds - 2640.0) < 0.01,
    string.format("timeline '44': expected 2640.0s, got %s", tostring(tl44.start_tc_seconds)))
print("  ✓ Timeline '44': start_tc_seconds = 2640.0")

-- Find the 23-hour timeline (name might vary)
local tl23 = nil
for _, tl in ipairs(result.timelines) do
    if tl.start_tc_seconds and math.abs(tl.start_tc_seconds - 82800.0) < 1.0 then
        tl23 = tl
        break
    end
end
assert(tl23, "23-hour timeline not found (expected start_tc_seconds ≈ 82800)")
assert(math.abs(tl23.start_tc_seconds - 82800.0) < 0.01,
    string.format("23hr timeline: expected 82800.0s, got %s", tostring(tl23.start_tc_seconds)))
print("  ✓ 23-hour timeline: start_tc_seconds = 82800.0")

-- =========================================================================
-- Test 2: start_tc_seconds → frames conversion at 24fps
-- =========================================================================
-- All 3 timelines in the test DRP are 24fps
local fps = 24
-- 33s * 24 = 792 frames
assert(math.floor(tl33.start_tc_seconds * fps + 0.5) == 792,
    "33s at 24fps should be 792 frames")
-- 2640s * 24 = 63360 frames
assert(math.floor(tl44.start_tc_seconds * fps + 0.5) == 63360,
    "2640s at 24fps should be 63360 frames")
-- 82800s * 24 = 1987200 frames
assert(math.floor(tl23.start_tc_seconds * fps + 0.5) == 1987200,
    "82800s at 24fps should be 1987200 frames")
print("  ✓ seconds → frames conversion correct at 24fps")

print("✅ test_drp_start_timecode.lua passed")
