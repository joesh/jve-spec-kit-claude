#!/usr/bin/env luajit
--- T004: Segment filename matching — basename suffix variants
-- Tests match_segment_filename() which doesn't exist yet — MUST FAIL.
require("test_env")

print("=== test_segment_matching.lua ===")

local relinker = require("core.media_relinker")

---------------------------------------------------------------------------------
-- match_segment_filename(original_basename, candidate_basename)
-- Returns true if candidate is a segment variant of original.
-- Segment = original basename + numeric suffix (_001, _002, etc.)
-- Case-insensitive comparison.
---------------------------------------------------------------------------------

print("\n--- match_segment_filename ---")

-- Test 1: Exact match (not a segment — segments have suffixes)
do
    local result = relinker.match_segment_filename("A026_C007.mov", "A026_C007.mov")
    assert(result == false, "exact match should not be a segment match")
    print("  ✓ exact same name → false (not a segment)")
end

-- Test 2: Numeric suffix _001
do
    local result = relinker.match_segment_filename("A026_C007.mov", "A026_C007_001.mov")
    assert(result == true, "suffix _001 should match")
    print("  ✓ A026_C007.mov matches A026_C007_001.mov")
end

-- Test 3: Numeric suffix _002
do
    local result = relinker.match_segment_filename("A026_C007.mov", "A026_C007_002.mov")
    assert(result == true, "suffix _002 should match")
    print("  ✓ A026_C007.mov matches A026_C007_002.mov")
end

-- Test 4: Case-insensitive
do
    local result = relinker.match_segment_filename("A026_C007.MOV", "a026_c007_001.mov")
    assert(result == true, "case-insensitive should match")
    print("  ✓ case-insensitive segment matching works")
end

-- Test 5: Non-numeric suffix rejected
do
    local result = relinker.match_segment_filename("A026_C007.mov", "A026_C007_extra.mov")
    assert(result == false, "non-numeric suffix should be rejected")
    print("  ✓ A026_C007_extra.mov rejected (non-numeric suffix)")
end

-- Test 6: Different extension rejected
do
    local result = relinker.match_segment_filename("A026_C007.mov", "A026_C007_001.mp4")
    assert(result == false, "different extension should be rejected")
    print("  ✓ different extension rejected")
end

-- Test 7: Completely different name
do
    local result = relinker.match_segment_filename("A026_C007.mov", "B001_C001_001.mov")
    assert(result == false, "different basename should be rejected")
    print("  ✓ different basename rejected")
end

-- Test 8: Suffix with more digits (media-managed can use longer numbers)
do
    local result = relinker.match_segment_filename("Interview.wav", "Interview_0001.wav")
    assert(result == true, "4-digit suffix should match")
    print("  ✓ Interview.wav matches Interview_0001.wav (4-digit suffix)")
end

-- Test 9: Suffix without underscore — should NOT match
-- Resolve uses underscore-separated suffixes only
do
    local result = relinker.match_segment_filename("A026_C007.mov", "A026_C0071.mov")
    assert(result == false, "suffix without underscore should be rejected")
    print("  ✓ A026_C0071.mov rejected (no underscore separator)")
end

-- Test 10: Name with dots in basename
do
    local result = relinker.match_segment_filename("take.1.final.mov", "take.1.final_001.mov")
    assert(result == true, "dotted basename with segment suffix should match")
    print("  ✓ dotted basename with segment suffix matches")
end

---------------------------------------------------------------------------------
-- build_segment_index(candidate_index)
-- Given a normal basename→paths index, returns an additional
-- segment_index mapping original_basename → [segment_paths]
-- Only called when accept_filename_suffixes is enabled.
---------------------------------------------------------------------------------

print("\n--- build_segment_index ---")

-- Test 11: Segment index groups segment files under original basename
do
    local candidate_index = {
        ["a026_c007.mov"] = {"/vol/A026_C007.mov"},
        ["a026_c007_001.mov"] = {"/vol/A026_C007_001.mov"},
        ["a026_c007_002.mov"] = {"/vol/A026_C007_002.mov"},
        ["b001_c001.mov"] = {"/vol/B001_C001.mov"},
    }
    local seg_index = relinker.build_segment_index(candidate_index)
    assert(seg_index, "build_segment_index should return a table")

    local segments = seg_index["a026_c007.mov"]
    assert(segments, "should have segments for a026_c007.mov")
    assert(#segments == 2, string.format("expected 2 segments, got %d", #segments))
    print("  ✓ segment index groups _001/_002 under original basename")
end

print("\n✅ test_segment_matching.lua passed")
