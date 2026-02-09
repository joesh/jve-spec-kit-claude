#!/usr/bin/env luajit
-- Test: Edge selection for narrow vs wide clips
--
-- For narrow clips (< MIN_EDGE_SELECTABLE_WIDTH_PX):
--   - Edges should NOT be selectable
--   - Clip body should still be selectable in the middle
--
-- For wide clips (>= MIN_EDGE_SELECTABLE_WIDTH_PX):
--   - Edges should be selectable
--   - Clip body should be selectable in the middle

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

local edge_picker = require("ui.timeline.edge_picker")
local ui_constants = require("core.ui_constants")

local EDGE = ui_constants.TIMELINE.EDGE_ZONE_PX
local ROLL = ui_constants.TIMELINE.ROLL_ZONE_PX or EDGE
local MIN_WIDTH = ui_constants.TIMELINE.MIN_EDGE_SELECTABLE_WIDTH_PX

assert(MIN_WIDTH, "MIN_EDGE_SELECTABLE_WIDTH_PX must be defined")
assert(MIN_WIDTH == 17, "MIN_EDGE_SELECTABLE_WIDTH_PX should be 17")

local function make_clip(id, start_frames, dur_frames)
    return {
        id = id,
        track_id = "v1",
        timeline_start = start_frames,
        duration = dur_frames
    }
end

local function pick(clips, x, custom_min_width)
    return edge_picker.pick_edges(clips, x, 2000, {
        edge_zone = EDGE,
        roll_zone = ROLL,
        time_to_pixel = function(t) return t end,
        min_edge_selectable_width = custom_min_width
    })
end

-- =============================================================================
-- TEST 1: Narrow clip (5px) - edges NOT selectable
-- =============================================================================
do
    -- Wide clips on either side to isolate the narrow clip
    local before = make_clip("before", 0, 100)     -- frames 0-100
    local narrow = make_clip("narrow", 100, 5)     -- frames 100-105 (5px, below threshold)
    local after = make_clip("after", 105, 100)     -- frames 105-205
    local clips = {before, narrow, after}

    -- At left edge of narrow clip (frame 100): before.out + narrow.in
    local left_edge = pick(clips, 100)
    assert(left_edge.roll_used == false, "TEST 1a: roll should be disabled at narrow clip edge")
    assert(#left_edge.selection == 1, "TEST 1a: only one edge selectable")
    assert(left_edge.selection[1].clip_id == "before", "TEST 1a: should select before.out, not narrow.in")

    -- At right edge of narrow clip (frame 105): narrow.out + after.in
    local right_edge = pick(clips, 105)
    assert(right_edge.roll_used == false, "TEST 1b: roll should be disabled at narrow clip edge")
    assert(#right_edge.selection == 1, "TEST 1b: only one edge selectable")
    assert(right_edge.selection[1].clip_id == "after", "TEST 1b: should select after.in, not narrow.out")
end
print("  ✓ Test 1: Narrow clip (5px) edges not selectable")

-- =============================================================================
-- TEST 2: Wide clip (17px, at threshold) - edges ARE selectable
-- =============================================================================
do
    local before = make_clip("before", 0, 100)     -- frames 0-100
    local wide = make_clip("wide", 100, 17)        -- frames 100-117 (17px, at threshold)
    local after = make_clip("after", 117, 100)     -- frames 117-217
    local clips = {before, wide, after}

    -- At left edge (frame 100): before.out + wide.in - both selectable, roll works
    local left_edge = pick(clips, 100)
    assert(left_edge.roll_used == true, "TEST 2a: roll should work at wide clip edge")
    assert(#left_edge.selection == 2, "TEST 2a: both edges selectable for roll")

    -- At right edge (frame 117): wide.out + after.in - both selectable, roll works
    local right_edge = pick(clips, 117)
    assert(right_edge.roll_used == true, "TEST 2b: roll should work at wide clip edge")
    assert(#right_edge.selection == 2, "TEST 2b: both edges selectable for roll")
end
print("  ✓ Test 2: Wide clip (17px) edges selectable, roll works")

-- =============================================================================
-- TEST 3: Middle of wide clip - no edge selection (clip body selection separate)
-- Edge picker only works near boundaries, so middle of clip = no edge selection
-- (Clip body selection is handled separately by find_clip_under_cursor)
-- =============================================================================
do
    local wide = make_clip("wide", 100, 100)       -- frames 100-200

    -- Middle of wide clip (frame 150) - well outside edge zone (10px), no edge selection
    local wide_middle = pick({wide}, 150)
    assert(#wide_middle.selection == 0, "TEST 3: no edge selection in middle of wide clip")
end
print("  ✓ Test 3: Middle of clip has no edge selection (clip body handled separately)")

-- =============================================================================
-- TEST 4: Narrow gap (5px) - gap edges NOT selectable
-- =============================================================================
do
    local clip1 = make_clip("a", 0, 100)           -- frames 0-100
    local clip2 = make_clip("b", 105, 100)         -- frames 105-205 (5px gap)
    local clips = {clip1, clip2}

    -- At start of gap (frame 100): clip1.out + gap_after
    local gap_start = pick(clips, 100)
    assert(gap_start.roll_used == false, "TEST 4a: roll disabled for narrow gap")
    assert(#gap_start.selection == 1, "TEST 4a: only clip edge selectable")
    assert(gap_start.selection[1].edge_type == "out", "TEST 4a: should select clip1.out")

    -- At end of gap (frame 105): gap_before + clip2.in
    local gap_end = pick(clips, 105)
    assert(gap_end.roll_used == false, "TEST 4b: roll disabled for narrow gap")
    assert(#gap_end.selection == 1, "TEST 4b: only clip edge selectable")
    assert(gap_end.selection[1].edge_type == "in", "TEST 4b: should select clip2.in")
end
print("  ✓ Test 4: Narrow gap (5px) edges not selectable")

-- =============================================================================
-- TEST 5: Wide gap (100px) - gap edges ARE selectable
-- =============================================================================
do
    local clip1 = make_clip("a", 0, 100)           -- frames 0-100
    local clip2 = make_clip("b", 200, 100)         -- frames 200-300 (100px gap)
    local clips = {clip1, clip2}

    -- At start of gap (frame 100): clip1.out + gap_after - roll works
    local gap_start = pick(clips, 100)
    assert(gap_start.roll_used == true, "TEST 5a: roll works for wide gap")
    assert(#gap_start.selection == 2, "TEST 5a: both edges selectable")

    -- At end of gap (frame 200): gap_before + clip2.in - roll works
    local gap_end = pick(clips, 200)
    assert(gap_end.roll_used == true, "TEST 5b: roll works for wide gap")
    assert(#gap_end.selection == 2, "TEST 5b: both edges selectable")
end
print("  ✓ Test 5: Wide gap (100px) edges selectable, roll works")

-- =============================================================================
-- TEST 6: Abutting wide clips - roll works normally
-- =============================================================================
do
    local clip1 = make_clip("a", 0, 100)
    local clip2 = make_clip("b", 100, 100)
    local clips = {clip1, clip2}

    local result = pick(clips, 100)
    assert(result.roll_used == true, "TEST 6: abutting wide clips should allow roll")
    assert(#result.selection == 2, "TEST 6: both edges selectable")
end
print("  ✓ Test 6: Abutting wide clips allow roll")

-- =============================================================================
-- TEST 7: Custom min_width override
-- =============================================================================
do
    local before = make_clip("before", 0, 50)
    local test_clip = make_clip("test", 50, 12)    -- 12px (below default 17)
    local after = make_clip("after", 62, 50)
    local clips = {before, test_clip, after}

    -- With default threshold (17), 12px clip edges not selectable
    local default_result = pick(clips, 50)
    assert(default_result.roll_used == false, "TEST 7a: roll disabled with default threshold")

    -- With custom threshold (10), 12px clip edges are selectable
    local custom_result = pick(clips, 50, 10)
    assert(custom_result.roll_used == true, "TEST 7b: roll works with lower threshold")
end
print("  ✓ Test 7: Custom min_width override works")

print("✅ test_edge_picker_narrow_clip.lua passed")
