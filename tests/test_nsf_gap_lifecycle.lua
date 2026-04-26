#!/usr/bin/env luajit

-- NSF: gap_lifecycle must not silently accept broken data.
-- Tests for input validation AND output invariants.

require("test_env")

local gap_lifecycle = require("core.gap_lifecycle")

local SEQ_FPS = { fps_numerator = 24, fps_denominator = 1 }

local function media_clip(id, track_id, start, dur)
    return {
        id = id, track_id = track_id, timeline_start = start, duration = dur,
        is_gap = false, media_id = "m1",
    }
end

-- ─────────────────────────────────────────────────────────────────────────
-- Half 1: Input validation
-- ─────────────────────────────────────────────────────────────────────────

print("--- NSF Half 1: Input validation ---")

-- compute_gaps_for_track: nil track_id must assert
do
    local ok, err = pcall(gap_lifecycle.compute_gaps_for_track, nil, {}, SEQ_FPS)
    assert(not ok, "nil track_id must assert")
    assert(tostring(err):find("track_id"), "error must mention track_id: " .. tostring(err))
end
print("  ✓ nil track_id asserts")

-- compute_gaps_for_track: nil seq_fps must assert
do
    local ok, err = pcall(gap_lifecycle.compute_gaps_for_track, "v1", {}, nil)
    assert(not ok, "nil seq_fps must assert")
    assert(tostring(err):find("seq_fps"), "error must mention seq_fps: " .. tostring(err))
end
print("  ✓ nil seq_fps asserts")

-- compute_gaps_for_track: clip with nil timeline_start must assert
do
    local bad_clip = { id = "bad", track_id = "v1", duration = 100 }
    local ok, err = pcall(gap_lifecycle.compute_gaps_for_track, "v1", {bad_clip}, SEQ_FPS)
    assert(not ok, "clip with nil timeline_start must assert")
    assert(tostring(err):find("timeline_start"), "error must mention timeline_start: " .. tostring(err))
end
print("  ✓ clip with nil timeline_start asserts")

-- create_implied_gap: nil position must assert
do
    local ok = pcall(gap_lifecycle.create_implied_gap, "v1", nil, SEQ_FPS)
    assert(not ok, "nil position must assert")
end
print("  ✓ nil position asserts")

-- ─────────────────────────────────────────────────────────────────────────
-- Half 2: Output invariants
-- ─────────────────────────────────────────────────────────────────────────

print("--- NSF Half 2: Output invariants ---")

-- Overlapping clips: transient state during overwrite/insert before occlusion.
-- No gap in overlapping region, no crash.
do
    local clips = {
        media_clip("c1", "v1", 0, 200),
        media_clip("c2", "v1", 100, 200),  -- overlaps c1
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 0, "overlapping clips produce no gaps")
end
print("  ✓ overlapping clips produce no gaps (transient overwrite state)")

-- Overlapping then gap: c1[0-200] c2[100-200] c3[400-500] → gap [200-400]
do
    local clips = {
        media_clip("c1", "v1", 0, 200),
        media_clip("c2", "v1", 100, 100),  -- overlaps c1 but ends at same point
        media_clip("c3", "v1", 400, 100),
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)
    assert(#gaps == 1, string.format("expected 1 gap after overlap, got %d", #gaps))
    assert(gaps[1].timeline_start == 200, "gap should start at 200")
    assert(gaps[1].duration == 200, "gap should be 200 frames")
end
print("  ✓ overlap followed by gap computes correctly")

-- Computed gaps must satisfy invariants:
-- gap.timeline_start + gap.duration == next clip's timeline_start
do
    local clips = {
        media_clip("c1", "v1", 50, 100),
        media_clip("c2", "v1", 300, 100),
        media_clip("c3", "v1", 500, 100),
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("v1", clips, SEQ_FPS)

    -- Head gap: [0, 50)
    assert(gaps[1].timeline_start == 0, "head gap starts at 0")
    assert(gaps[1].timeline_start + gaps[1].duration == clips[1].timeline_start,
        "gap end must equal next clip start")

    -- Gap between c1 and c2: [150, 300)
    assert(gaps[2].timeline_start == 150, "gap2 starts at 150")
    assert(gaps[2].timeline_start + gaps[2].duration == clips[2].timeline_start,
        "gap2 end must equal c2 start")

    -- All gaps must have is_gap = true
    for _, gap in ipairs(gaps) do
        assert(gap.is_gap == true, "gap must have clip_kind='gap'")
        assert(gap.media_id == nil, "gap must have nil media_id")
        assert(gap.duration >= 0, "gap duration must be >= 0")
    end
end
print("  ✓ gap invariants hold (contiguity, clip_kind, non-negative)")

-- create_implied_gap: output must have is_gap = true and duration = 0
do
    local gap = gap_lifecycle.create_implied_gap("v1", 100, SEQ_FPS)
    assert(gap, "create_implied_gap must return a gap")
    assert(gap.is_gap == true, "implied gap must have clip_kind='gap'")
    assert(gap.duration == 0, "implied gap must have duration 0")
    assert(gap.timeline_start == 100, "implied gap must be at requested position")
    assert(gap.track_id == "v1", "implied gap must have correct track_id")
    assert(gap.media_id == nil, "implied gap must have nil media_id")
end
print("  ✓ create_implied_gap output invariants")

print("✅ test_nsf_gap_lifecycle.lua passed")
