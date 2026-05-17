#!/usr/bin/env luajit

-- TDD tests for gap_lifecycle.create_implied_gap
-- All scenarios must FAIL until T010 implements the function.

require("test_env")

local gap_lifecycle = require("core.gap_lifecycle")

local SEQ_FPS = { fps_numerator = 24, fps_denominator = 1 }

-- (a) position between two adjacent clips → zero-length gap created
print("--- (a) zero-length gap at adjacent boundary ---")
do
    local gap = gap_lifecycle.create_implied_gap("v1", 100, SEQ_FPS)
    assert(gap ~= nil, "create_implied_gap should return a gap clip")
    assert(gap.is_gap == true, "clip_kind should be 'gap', got " .. tostring(gap.clip_kind))
    assert(gap.duration == 0, "implied gap duration should be 0, got " .. tostring(gap.duration))
    assert(gap.sequence_start == 100, "sequence_start should be 100, got " .. tostring(gap.sequence_start))
    assert(gap.track_id == "v1", "track_id should be 'v1', got " .. tostring(gap.track_id))
    assert(gap.media_id == nil, "media_id should be nil")
    assert(type(gap.id) == "string" and gap.id:find("^gap_"), "id should have gap_ prefix, got " .. tostring(gap.id))
end

-- (b) position at start of track with clip at 0 → zero-length gap at 0
print("--- (b) zero-length gap at position 0 ---")
do
    local gap = gap_lifecycle.create_implied_gap("v1", 0, SEQ_FPS)
    assert(gap ~= nil, "create_implied_gap should return a gap clip at position 0")
    assert(gap.duration == 0, "duration should be 0, got " .. tostring(gap.duration))
    assert(gap.sequence_start == 0, "sequence_start should be 0, got " .. tostring(gap.sequence_start))
    assert(gap.track_id == "v1", "track_id should be 'v1'")
    assert(gap.fps_numerator == 24, "fps_numerator should be 24, got " .. tostring(gap.fps_numerator))
    assert(gap.fps_denominator == 1, "fps_denominator should be 1, got " .. tostring(gap.fps_denominator))
end

-- (c) different track ids produce different gap ids
print("--- (c) different tracks produce different gap ids ---")
do
    local g1 = gap_lifecycle.create_implied_gap("v1", 100, SEQ_FPS)
    local g2 = gap_lifecycle.create_implied_gap("a1", 100, SEQ_FPS)
    assert(g1 and g2, "both gaps should be created")
    assert(g1.id ~= g2.id, string.format("gap ids should differ: %s vs %s", g1.id, g2.id))
    assert(g1.track_id == "v1", "g1 track_id should be v1")
    assert(g2.track_id == "a1", "g2 track_id should be a1")
end

print("✅ test_gap_lifecycle_implied.lua passed")
