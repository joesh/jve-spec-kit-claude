require("test_env")

-- Regression tests: DRP import must handle degenerate data from real Resolve projects.
--
-- Fixture: sample_project_zero_duration.drp contains:
-- 1. A zero-duration video clip (Resolve artifact: speed changes, disabled items)
-- 2. An orphan sequence XML with no matching MediaPool metadata (compound clip, deleted timeline)
--
-- Both should be skipped with warnings, not crash the import.

local drp_importer = require("importers.drp_importer")

local DRP_PATH = "fixtures/resolve/sample_project_zero_duration.drp"

-- Check fixture exists
local f = io.open(DRP_PATH, "r")
assert(f, "Missing fixture: " .. DRP_PATH)
f:close()

print("Parsing DRP with degenerate data...")
local result = drp_importer.parse_drp_file(DRP_PATH)

assert(result.success, "parse_drp_file should not crash on degenerate data, got: " .. tostring(result.error))

-- Test 1: Zero-duration clips are excluded
print("Test 1: Zero-duration clips skipped")
local found_zero = false
for _, tl in ipairs(result.timelines) do
    for _, track in ipairs(tl.tracks or {}) do
        for _, clip in ipairs(track.clips or {}) do
            if clip.name == "zero-duration-clip" then
                found_zero = true
            end
            assert(clip.duration > 0, string.format(
                "Clip '%s' has duration=%d - zero-duration clips should be skipped",
                clip.name, clip.duration))
        end
    end
end
assert(not found_zero, "Zero-duration clip 'zero-duration-clip' should have been skipped")
print("  PASS: no zero-duration clips in output")

-- Test 2: Orphan sequences (no MediaPool metadata) are skipped
print("Test 2: Orphan sequences skipped")
local found_orphan = false
for _, tl in ipairs(result.timelines) do
    if tl.name == "orphan-clip" then
        found_orphan = true
    end
end
assert(not found_orphan, "Orphan sequence should have been skipped")

-- Valid timelines from sample_project.drp should still be present
assert(#result.timelines >= 5, string.format(
    "Expected at least 5 timelines (got %d) - valid timelines should still parse",
    #result.timelines))
print("  PASS: " .. #result.timelines .. " valid timelines parsed, orphan excluded")

-- Test 3: Valid clips still parse normally
print("Test 3: Valid clips intact")
local total_clips = 0
for _, tl in ipairs(result.timelines) do
    for _, track in ipairs(tl.tracks or {}) do
        total_clips = total_clips + #(track.clips or {})
    end
end
assert(total_clips > 0, "Should have parsed non-zero-duration clips successfully")
print("  PASS: " .. total_clips .. " clips across all timelines")

print("✅ test_drp_import_degenerate_clips.lua passed")
