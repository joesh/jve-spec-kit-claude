#!/usr/bin/env luajit
--- T003: TC offset math — compute_tc_offset + adjust_source_range
-- These functions don't exist yet in media_relinker — tests MUST FAIL.
require("test_env")

print("=== test_tc_offset.lua ===")

local relinker = require("core.media_relinker")

---------------------------------------------------------------------------------
-- compute_tc_offset(stored_value, stored_rate, candidate_value, candidate_rate)
-- Returns offset in frames at stored_rate.
-- Offset = candidate_tc - stored_tc (both rescaled to stored_rate).
---------------------------------------------------------------------------------

print("\n--- compute_tc_offset ---")

-- Test 1: Same TC → offset 0
do
    local offset = relinker.compute_tc_offset(89750, 25, 89750, 25)
    assert(offset == 0, string.format("same TC: expected 0, got %s", tostring(offset)))
    print("  ✓ same TC same rate → offset 0")
end

-- Test 2: Candidate starts later → positive offset
-- stored=89750 @ 25fps (00:59:50:00), candidate=89775 @ 25fps (00:59:51:00)
do
    local offset = relinker.compute_tc_offset(89750, 25, 89775, 25)
    assert(offset == 25, string.format("later TC: expected 25, got %s", tostring(offset)))
    print("  ✓ candidate later → positive offset (25 frames)")
end

-- Test 3: Candidate starts earlier → negative offset
do
    local offset = relinker.compute_tc_offset(89750, 25, 89700, 25)
    assert(offset == -50, string.format("earlier TC: expected -50, got %s", tostring(offset)))
    print("  ✓ candidate earlier → negative offset (-50 frames)")
end

-- Test 4: Cross-rate comparison — stored @ 25fps, candidate @ 48000Hz (BWF audio)
-- stored=89750 frames @ 25fps = 3590 seconds
-- candidate=172320000 samples @ 48000Hz = 3590 seconds → offset should be 0
do
    local offset = relinker.compute_tc_offset(89750, 25, 172320000, 48000)
    assert(offset == 0, string.format("cross-rate same TC: expected 0, got %s", tostring(offset)))
    print("  ✓ cross-rate (25fps vs 48000Hz) same absolute TC → offset 0")
end

-- Test 5: Cross-rate with actual offset
-- stored=89750 frames @ 25fps = 3590s
-- candidate=172368000 samples @ 48000Hz = 3591s → offset = 1s = 25 frames @ 25fps
do
    local offset = relinker.compute_tc_offset(89750, 25, 172368000, 48000)
    assert(offset == 25, string.format("cross-rate offset: expected 25, got %s", tostring(offset)))
    print("  ✓ cross-rate with 1s offset → 25 frames")
end

-- Test 6: Large offset (media-managed copy trimmed by 27 seconds)
-- stored=89750 @ 25 (00:59:50:00), candidate=90425 @ 25 (01:00:17:00)
do
    local offset = relinker.compute_tc_offset(89750, 25, 90425, 25)
    assert(offset == 675, string.format("large offset: expected 675, got %s", tostring(offset)))
    print("  ✓ large offset (27s trim) → 675 frames")
end

---------------------------------------------------------------------------------
-- adjust_source_range REMOVED — source_in/source_out are absolute TC and must
-- never be modified during relink. TC is the source of truth for content identity.
-- C++ computes file_pos = source_in - first_sample_tc at decode time.
---------------------------------------------------------------------------------

print("\n✅ test_tc_offset.lua passed")
