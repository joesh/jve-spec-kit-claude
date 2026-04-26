#!/usr/bin/env luajit

-- TDD tests for gap_lifecycle.compute_gaps_for_track
-- All scenarios must FAIL until T008 implements the function.

require("test_env")

local gap_lifecycle = require("core.gap_lifecycle")

local SEQ_FPS = { fps_numerator = 24, fps_denominator = 1 }

-- Helper: build a minimal media clip
local function clip(id, track_id, start, dur)
    return {
        id = id,
        track_id = track_id,
        timeline_start = start,
        duration = dur,
        is_gap = false,
        media_id = "media_1",
        source_in = 0,
        source_out = dur,
        fps_numerator = 24,
        fps_denominator = 1,
    }
end

-- Helper: verify gap clip fields
local function assert_gap(gap, expected_start, expected_dur, track_id, label)
    assert(gap, label .. ": gap is nil")
    assert(gap.is_gap == true, string.format("%s: clip_kind=%s, expected gap", label, tostring(gap.clip_kind)))
    assert(gap.media_id == nil, string.format("%s: media_id should be nil", label))
    assert(gap.track_id == track_id, string.format("%s: track_id=%s, expected %s", label, tostring(gap.track_id), tostring(track_id)))
    assert(gap.timeline_start == expected_start,
        string.format("%s: timeline_start=%s, expected %d", label, tostring(gap.timeline_start), expected_start))
    assert(gap.duration == expected_dur,
        string.format("%s: duration=%s, expected %d", label, tostring(gap.duration), expected_dur))
    assert(type(gap.id) == "string" and gap.id:find("^gap_"), string.format("%s: id=%s, expected gap_ prefix", label, tostring(gap.id)))
end

-- (a) empty track → no gaps
print("--- (a) empty track → no gaps ---")
do
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", {}, SEQ_FPS)
    assert(type(gaps) == "table", "should return table")
    assert(#gaps == 0, string.format("empty track should produce 0 gaps, got %d", #gaps))
end

-- (b) single clip not at 0 → gap before clip
print("--- (b) single clip not at 0 → gap before clip ---")
do
    local clips = { clip("c1", "v1", 100, 200) }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 1, string.format("expected 1 gap, got %d", #gaps))
    assert_gap(gaps[1], 0, 100, "v1", "gap before c1")
end

-- (c) two clips with space → gap between them
print("--- (c) two clips with space → gap between ---")
do
    local clips = {
        clip("c1", "v1", 0, 100),
        clip("c2", "v1", 300, 100),
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 1, string.format("expected 1 gap, got %d", #gaps))
    assert_gap(gaps[1], 100, 200, "v1", "gap between c1-c2")
end

-- (d) two adjacent clips → no gap between them
print("--- (d) two adjacent clips → no gap ---")
do
    local clips = {
        clip("c1", "v1", 0, 100),
        clip("c2", "v1", 100, 200),
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 0, string.format("adjacent clips should produce 0 gaps, got %d", #gaps))
end

-- (e) three clips with two gaps → two gap clips
print("--- (e) three clips with two gaps → two gaps ---")
do
    local clips = {
        clip("c1", "v1", 0, 100),
        clip("c2", "v1", 200, 100),
        clip("c3", "v1", 400, 100),
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 2, string.format("expected 2 gaps, got %d", #gaps))
    assert_gap(gaps[1], 100, 100, "v1", "gap c1-c2")
    assert_gap(gaps[2], 300, 100, "v1", "gap c2-c3")
end

-- (f) clip at position 0 → no leading gap
print("--- (f) clip at position 0 → no leading gap ---")
do
    local clips = { clip("c1", "v1", 0, 200) }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 0, string.format("clip at 0 should produce 0 gaps, got %d", #gaps))
end

-- (g) non-trivial: clip at 50 with gap at head, clip at 300 with gap between, clip at 500 adjacent
print("--- (g) mixed layout: head gap + internal gap + adjacent ---")
do
    local clips = {
        clip("c1", "v1", 50, 100),
        clip("c2", "v1", 300, 100),
        clip("c3", "v1", 400, 100),
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 2, string.format("expected 2 gaps, got %d", #gaps))
    assert_gap(gaps[1], 0, 50, "v1", "head gap")
    assert_gap(gaps[2], 150, 150, "v1", "gap c1-c2")
    -- no gap between c2 and c3 (adjacent at 400)
end

print("✅ test_gap_lifecycle_compute.lua passed")
