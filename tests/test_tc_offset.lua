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
-- adjust_source_range(source_in, source_out, offset, clip_rate)
-- Returns new_source_in, new_source_out after applying TC offset.
-- If new_source_in < 0 → returns nil, nil (clip falls outside candidate range).
-- offset is in frames at the same rate as source_in/source_out (clip_rate).
---------------------------------------------------------------------------------

print("\n--- adjust_source_range ---")

-- Test 7: Zero offset → unchanged
do
    local new_in, new_out = relinker.adjust_source_range(100, 200, 0, 25)
    assert(new_in == 100, string.format("zero offset in: expected 100, got %s", tostring(new_in)))
    assert(new_out == 200, string.format("zero offset out: expected 200, got %s", tostring(new_out)))
    print("  ✓ zero offset → source range unchanged")
end

-- Test 8: Positive offset (candidate starts later) → source_in decreases
-- If candidate starts 25 frames later, the clip's source_in relative to
-- the candidate must shift back by 25 frames.
do
    local new_in, new_out = relinker.adjust_source_range(100, 200, 25, 25)
    assert(new_in == 75, string.format("positive offset in: expected 75, got %s", tostring(new_in)))
    assert(new_out == 175, string.format("positive offset out: expected 175, got %s", tostring(new_out)))
    print("  ✓ positive offset → source range shifted back")
end

-- Test 9: Negative offset (candidate starts earlier) → source_in increases
do
    local new_in, new_out = relinker.adjust_source_range(100, 200, -50, 25)
    assert(new_in == 150, string.format("negative offset in: expected 150, got %s", tostring(new_in)))
    assert(new_out == 250, string.format("negative offset out: expected 250, got %s", tostring(new_out)))
    print("  ✓ negative offset → source range shifted forward")
end

-- Test 10: Offset makes source_in negative → returns nil (out of range)
do
    local new_in, new_out = relinker.adjust_source_range(10, 50, 25, 25)
    assert(new_in == nil, "source_in < 0: expected nil")
    assert(new_out == nil, "source_out when OOR: expected nil")
    print("  ✓ offset causing negative source_in → nil, nil")
end

-- Test 11: Cross-rate offset adjustment (offset computed at stored_rate,
-- but source_in/source_out are in clip_rate — the caller must rescale
-- the offset to clip_rate before calling this function)
-- This test verifies the function works with already-rescaled values.
do
    -- Audio clip: source_in=480000 samples, source_out=960000 samples
    -- Offset=48000 samples (1 second earlier in candidate)
    local new_in, new_out = relinker.adjust_source_range(480000, 960000, 48000, 48000)
    assert(new_in == 432000, string.format("audio offset in: expected 432000, got %s", tostring(new_in)))
    assert(new_out == 912000, string.format("audio offset out: expected 912000, got %s", tostring(new_out)))
    print("  ✓ audio sample offset adjustment works")
end

-- Test 12: Edge case — source_in exactly equals offset → new_source_in = 0 (valid)
do
    local new_in, new_out = relinker.adjust_source_range(50, 100, 50, 25)
    assert(new_in == 0, string.format("edge zero in: expected 0, got %s", tostring(new_in)))
    assert(new_out == 50, string.format("edge zero out: expected 50, got %s", tostring(new_out)))
    print("  ✓ source_in exactly at offset → new_source_in = 0 (valid)")
end

print("\n✅ test_tc_offset.lua passed")
