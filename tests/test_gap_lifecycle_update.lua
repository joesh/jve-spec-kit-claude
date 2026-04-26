#!/usr/bin/env luajit

-- TDD tests for gap_lifecycle.update_gaps_after_edit
-- All scenarios must FAIL until T009 implements the function.

require("test_env")

local gap_lifecycle = require("core.gap_lifecycle")

local SEQ_FPS = { fps_numerator = 24, fps_denominator = 1 }

local function media_clip(id, track_id, start, dur)
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

local function gap_clip(track_id, start, dur)
    return {
        id = string.format("gap_%s_%d", track_id, start),
        track_id = track_id,
        timeline_start = start,
        duration = dur,
        is_gap = true,
        media_id = nil,
        source_in = nil,
        source_out = nil,
        fps_numerator = 24,
        fps_denominator = 1,
    }
end

-- Helper: extract gaps from mixed clip list
local function extract_gaps(clips)
    local gaps = {}
    for _, c in ipairs(clips) do
        if c.is_gap == true then
            table.insert(gaps, c)
        end
    end
    return gaps
end

-- Helper: extract media from mixed clip list
local function extract_media(clips)
    local result = {}
    for _, c in ipairs(clips) do
        if not c.is_gap then
            table.insert(result, c)
        end
    end
    return result
end

-- (a) clip trimmed shorter → gap grows
print("--- (a) clip trimmed shorter → gap grows ---")
do
    -- Before: c1[0..100] gap[100..300] c2[300..400]
    -- c1 trimmed to [0..80]: gap should become [80..300]
    local all_clips = {
        media_clip("c1", "v1", 0, 80),   -- trimmed from 100→80
        gap_clip("v1", 100, 200),         -- old gap (stale)
        media_clip("c2", "v1", 300, 100),
    }
    local result = gap_lifecycle.update_gaps_after_edit("v1", all_clips, {c1 = true}, SEQ_FPS)
    local gaps = extract_gaps(result)
    assert(#gaps == 1, string.format("expected 1 gap, got %d", #gaps))
    assert(gaps[1].timeline_start == 80, string.format("gap start=%d, expected 80", gaps[1].timeline_start))
    assert(gaps[1].duration == 220, string.format("gap duration=%d, expected 220", gaps[1].duration))
end

-- (b) clip trimmed longer → gap shrinks
print("--- (b) clip trimmed longer → gap shrinks ---")
do
    -- Before: c1[0..100] gap[100..300] c2[300..400]
    -- c1 trimmed to [0..150]: gap should become [150..300]
    local all_clips = {
        media_clip("c1", "v1", 0, 150),   -- trimmed from 100→150
        gap_clip("v1", 100, 200),          -- old gap (stale)
        media_clip("c2", "v1", 300, 100),
    }
    local result = gap_lifecycle.update_gaps_after_edit("v1", all_clips, {c1 = true}, SEQ_FPS)
    local gaps = extract_gaps(result)
    assert(#gaps == 1, string.format("expected 1 gap, got %d", #gaps))
    assert(gaps[1].timeline_start == 150, string.format("gap start=%d, expected 150", gaps[1].timeline_start))
    assert(gaps[1].duration == 150, string.format("gap duration=%d, expected 150", gaps[1].duration))
end

-- (c) gap shrinks to zero → gap deleted
print("--- (c) gap shrinks to zero → gap deleted ---")
do
    -- Before: c1[0..100] gap[100..300] c2[300..400]
    -- c1 trimmed to [0..300]: gap should disappear
    local all_clips = {
        media_clip("c1", "v1", 0, 300),
        gap_clip("v1", 100, 200),
        media_clip("c2", "v1", 300, 100),
    }
    local result = gap_lifecycle.update_gaps_after_edit("v1", all_clips, {c1 = true}, SEQ_FPS)
    local gaps = extract_gaps(result)
    assert(#gaps == 0, string.format("zero-duration gap should be deleted, got %d gaps", #gaps))
    local media = extract_media(result)
    assert(#media == 2, string.format("expected 2 media clips, got %d", #media))
end

-- (d) clip deleted → adjacent gaps merge
print("--- (d) clip deleted → adjacent gaps merge ---")
do
    -- Before: c1[0..100] gap1[100..200] c2[200..300] gap2[300..500] c3[500..600]
    -- c2 deleted: gap1 and gap2 should merge into one gap [100..500]
    -- After deletion, the all_clips list no longer contains c2
    local all_clips = {
        media_clip("c1", "v1", 0, 100),
        gap_clip("v1", 100, 100),          -- gap1
        gap_clip("v1", 300, 200),          -- gap2
        media_clip("c3", "v1", 500, 100),
    }
    local result = gap_lifecycle.update_gaps_after_edit("v1", all_clips, {c2 = true}, SEQ_FPS)
    local gaps = extract_gaps(result)
    assert(#gaps == 1, string.format("gaps should merge, expected 1, got %d", #gaps))
    assert(gaps[1].timeline_start == 100, string.format("merged gap start=%d, expected 100", gaps[1].timeline_start))
    assert(gaps[1].duration == 400, string.format("merged gap duration=%d, expected 400", gaps[1].duration))
end

-- (e) clip inserted in gap → gap splits into two
print("--- (e) clip inserted in gap → gap splits ---")
do
    -- Before: c1[0..100] gap[100..500] c2[500..600]
    -- New clip inserted at [200..300]: gap splits into [100..200] and [300..500]
    local all_clips = {
        media_clip("c1", "v1", 0, 100),
        gap_clip("v1", 100, 400),          -- old gap (stale)
        media_clip("c_new", "v1", 200, 100), -- newly inserted
        media_clip("c2", "v1", 500, 100),
    }
    local result = gap_lifecycle.update_gaps_after_edit("v1", all_clips, {c_new = true}, SEQ_FPS)
    local gaps = extract_gaps(result)
    assert(#gaps == 2, string.format("gap should split, expected 2, got %d", #gaps))
    assert(gaps[1].timeline_start == 100, string.format("gap1 start=%d, expected 100", gaps[1].timeline_start))
    assert(gaps[1].duration == 100, string.format("gap1 duration=%d, expected 100", gaps[1].duration))
    assert(gaps[2].timeline_start == 300, string.format("gap2 start=%d, expected 300", gaps[2].timeline_start))
    assert(gaps[2].duration == 200, string.format("gap2 duration=%d, expected 200", gaps[2].duration))
end

-- (f) clip inserted consuming entire gap → gap deleted
print("--- (f) clip consumes entire gap → gap deleted ---")
do
    -- Before: c1[0..100] gap[100..300] c2[300..400]
    -- New clip inserted at [100..300]: gap consumed entirely
    local all_clips = {
        media_clip("c1", "v1", 0, 100),
        gap_clip("v1", 100, 200),
        media_clip("c_fill", "v1", 100, 200), -- fills gap exactly
        media_clip("c2", "v1", 300, 100),
    }
    local result = gap_lifecycle.update_gaps_after_edit("v1", all_clips, {c_fill = true}, SEQ_FPS)
    local gaps = extract_gaps(result)
    assert(#gaps == 0, string.format("gap should be consumed, expected 0, got %d", #gaps))
end

print("✅ test_gap_lifecycle_update.lua passed")
