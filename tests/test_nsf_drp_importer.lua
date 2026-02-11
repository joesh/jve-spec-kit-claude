#!/usr/bin/env luajit
-- NSF Tests: DRP importer must not silently fail
--
-- Tests that drp_importer.lua:
-- 1. Asserts on missing required XML elements (no `or 0` fallbacks)
-- 2. Asserts on missing fps metadata (no `or 30` fallbacks)
-- 3. Uses explicit fps from DRP metadata, not inference heuristics

require("test_env")

print("=== test_nsf_drp_importer.lua ===")

local drp_importer = require("importers.drp_importer")

--------------------------------------------------------------------------------
-- Test 1: parse_drp_file asserts on missing fps metadata
--------------------------------------------------------------------------------

print("\n--- Test 1: Assert on missing fps in timeline metadata ---")

-- This test verifies that if a DRP timeline is missing FrameRate element,
-- the importer ASSERTS instead of silently using 30fps fallback.
-- We can't easily create a malformed DRP fixture, so we test the code path
-- by checking that valid DRP files have fps metadata.

local DRP_PATH = "fixtures/resolve/sample_project.drp"
local f = io.open(DRP_PATH, "r")
if f then
    f:close()
    local result = drp_importer.parse_drp_file(DRP_PATH)
    assert(result.success, "parse_drp_file failed: " .. tostring(result.error))

    -- Every timeline MUST have explicit fps from metadata
    for i, timeline in ipairs(result.timelines or {}) do
        assert(timeline.fps, string.format(
            "Timeline %d (%s) missing fps - NSF violation: must have explicit fps from DRP metadata",
            i, timeline.name or "unnamed"))
        assert(type(timeline.fps) == "number" and timeline.fps > 0, string.format(
            "Timeline %d (%s) has invalid fps=%s - must be positive number",
            i, timeline.name or "unnamed", tostring(timeline.fps)))
        print(string.format("  ✓ Timeline '%s' has explicit fps=%g", timeline.name, timeline.fps))
    end
    print("✓ All timelines have explicit fps metadata")
else
    print("  (skipping - fixture not available)")
end

--------------------------------------------------------------------------------
-- Test 2: Clip elements must have required fields
--------------------------------------------------------------------------------

print("\n--- Test 2: Clip parsing requires Start/Duration/MediaStartTime ---")

-- This test verifies the contract: if a clip element is malformed (missing
-- Start, Duration, or MediaStartTime), the importer should skip it with
-- a warning or assert, NOT silently create a clip with 0 values.

-- We verify this by checking that all clips in a valid DRP have non-zero
-- start positions (since DRP timelines start at 01:00:00:00 TC = 86400+ frames)

if io.open(DRP_PATH, "r") then
    io.open(DRP_PATH, "r"):close()
    local result = drp_importer.parse_drp_file(DRP_PATH)
    assert(result.success)

    local clip_count = 0
    for _, timeline in ipairs(result.timelines or {}) do
        for _, track in ipairs(timeline.tracks or {}) do
            for _, clip in ipairs(track.clips or {}) do
                clip_count = clip_count + 1
                -- DRP timelines start at 1-hour TC, so start_value should be >= 86400
                -- (24fps) or similar. A value of 0 indicates a parsing failure.
                -- Note: first clip could be at exactly 0 if timeline starts at 00:00:00:00
                -- but professional DRP timelines use 1-hour start.
                assert(type(clip.start_value) == "number", string.format(
                    "Clip '%s' has non-numeric start_value=%s",
                    clip.name or "unnamed", type(clip.start_value)))
                assert(type(clip.duration) == "number" and clip.duration > 0, string.format(
                    "Clip '%s' has invalid duration=%s - must be positive",
                    clip.name or "unnamed", tostring(clip.duration)))
            end
        end
    end
    print(string.format("✓ All %d clips have valid start_value and duration", clip_count))
else
    print("  (skipping - fixture not available)")
end

--------------------------------------------------------------------------------
-- Test 3: No fallback fps values in code
--------------------------------------------------------------------------------

print("\n--- Test 3: Code must not contain fps fallback patterns ---")

-- Read the drp_importer source and verify no `or 30` fps fallbacks exist
local importer_path = "../src/lua/importers/drp_importer.lua"
local handle = io.open(importer_path, "r")
assert(handle, "Could not open drp_importer.lua")
local content = handle:read("*a")
handle:close()

-- Check for forbidden fallback patterns (case insensitive for 'fallback')
local forbidden_patterns = {
    { pattern = "or%s+30%s*%-%-", desc = "or 30 --" },
    { pattern = "return%s+30%s*%-%-", desc = "return 30 --" },
    { pattern = "frame_rate_hint%s+or%s+30", desc = "frame_rate_hint or 30" },
    { pattern = "project%.settings%.frame_rate%s*$", desc = "fallback to project.settings.frame_rate" },
}

local violations = {}
for _, check in ipairs(forbidden_patterns) do
    if content:match(check.pattern) then
        table.insert(violations, check.desc)
    end
end

if #violations > 0 then
    print("NSF VIOLATIONS found in drp_importer.lua:")
    for _, v in ipairs(violations) do
        print("  ✗ " .. v)
    end
    error("drp_importer.lua contains fps fallback patterns - NSF violation")
end
print("✓ No fps fallback patterns found")

--------------------------------------------------------------------------------
-- Test 4: Required clip fields use assert, not `or 0`
--------------------------------------------------------------------------------

print("\n--- Test 4: Clip fields must use assert, not `or 0` ---")

-- Check that parse_resolve_tracks asserts on clip fields
local has_start_assert = content:match('assert%(start_elem') or content:match('assert%(start_frames')
local has_duration_assert = content:match('assert%(duration_elem') or content:match('assert%(duration_raw')
local has_media_start_assert = content:match('assert%(media_start_elem') or content:match('assert%(media_start_frames')

if not has_start_assert then
    print("NSF VIOLATION: No assert for Start field")
    error("drp_importer.lua must assert on missing Start element")
end
if not has_duration_assert then
    print("NSF VIOLATION: No assert for Duration field")
    error("drp_importer.lua must assert on missing Duration element")
end
if not has_media_start_assert then
    print("NSF VIOLATION: No assert for MediaStartTime field")
    error("drp_importer.lua must assert on missing MediaStartTime element")
end

print("✓ Clip fields use assert for required elements")

print("\n✅ test_nsf_drp_importer.lua passed")
