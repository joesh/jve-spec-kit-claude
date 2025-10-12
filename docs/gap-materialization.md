# Gap Materialization in Ripple Operations

**Date**: 2025-10-12
**Status**: FIXED ✅
**Bug ID**: BatchRippleEdit Bug #3

## Overview

Gap edges in multi-edge ripple operations were incorrectly trying to modify adjacent clips instead of creating virtual gap clip objects. This caused media boundary errors when trimming gaps.

## The Problem

### Incorrect Implementation (BEFORE)

```lua
if edge_info.edge_type == "gap_after" then
    clip = reference_clip  -- Load adjacent clip
    actual_edge_type = "in"
    is_gap_clip = false  -- ❌ Treated as real clip!
end

apply_edge_ripple(clip, actual_edge_type, delta)  -- ❌ Modifies adjacent clip
```

**What went wrong:**
- Gap `[` at 3s selected empty space after V1 clip
- Code loaded V1 clip and tried to modify its `source_in`
- Dragging left set `source_in = -1223` → blocked (media boundary)
- Operation failed instead of closing gap

### User-Reported Bug

```
Selected edges:
- V2 out-point ] at 5s
- V1 gap [ at 3s (empty space after first clip)

Dragged left -1223ms

ERROR: Drag failed
DEBUG in-point: clip=2e3a86ec, source_in=0, delta=-1223, new_source_in=-1223
BLOCKED: new_source_in=-1223 < 0 (can't rewind past start of media)
```

## The Solution

### Correct Implementation (AFTER)

```lua
if edge_info.edge_type == "gap_after" then
    -- Calculate gap boundaries from adjacent clips
    local gap_start = reference_clip.start_time + reference_clip.duration
    local gap_end = find_next_clip_start(reference_clip.track_id, gap_start)
    local gap_duration = gap_end - gap_start

    -- Create temporary virtual gap clip
    clip = {
        id = "temp_gap_" .. edge_info.clip_id,
        track_id = reference_clip.track_id,
        start_time = gap_start,
        duration = gap_duration,
        source_in = 0,
        source_out = gap_duration
    }
    actual_edge_type = "in"  -- gap_after = left edge of gap = in-point
    is_gap_clip = true  -- Don't save to database
end

apply_edge_ripple(clip, actual_edge_type, delta)  -- ✅ Modifies gap, not real clip
```

**What's correct:**
- Gap is materialized as temporary clip object
- Trimming gap modifies gap duration, not adjacent clips
- Gap "media" is 0 to duration → always valid (no boundary errors)
- After processing, gap is discarded (not saved to database)

## Design Principle: No Special Cases

The correct algorithm follows this pattern:

1. **Materialize**: Convert gap edges to temporary gap clip objects
2. **Process**: Apply ripple operation uniformly (gaps and clips identical)
3. **Cleanup**: Skip database save for gap clips

This eliminates all special case logic - gaps behave exactly like clips.

## Gap Edge Semantics

```
Timeline:  [Clip A]  ___GAP___  [Clip B]
           0ms    3000ms     5000ms

gap_after Clip A:
  - Left edge of gap [ at 3000ms
  - Edge type: "in" (closing gap pulls left)
  - Dragging right: duration decreases, Clip B shifts left

gap_before Clip B:
  - Right edge of gap ] at 5000ms
  - Edge type: "out" (extending gap pushes right)
  - Dragging right: duration increases, Clip B shifts right
```

## Test Coverage

**Test 11: Gap + Clip, Drag Right**
```lua
-- V2 out-point ] at 5s + V1 gap [ at 3s, drag RIGHT +500ms
-- Expected: V2 extends, gap shrinks (in-point behavior)
assert_eq(get_clip("clip_v2_1").duration, 3000)  -- Extended
assert_eq(get_clip("clip_v1_1").duration, 3000)  -- Unchanged (gap != clip)
assert_eq(get_clip("clip_v1_2").start_time, 5500) -- Shifted right
```

**Test 12: Gap + Clip, Drag Left (User's Bug)**
```lua
-- V2 out-point ] at 5s + V1 gap [ at 3s, drag LEFT -500ms
-- Expected: V2 shrinks, gap closes
assert_eq(get_clip("clip_v2_1").duration, 2000)  -- Trimmed
assert_eq(get_clip("clip_v1_1").duration, 3000)  -- Unchanged (gap != clip)
assert_eq(get_clip("clip_v1_2").start_time, 4500) -- Shifted left (gap closed)
```

## Key Insights

1. **Gaps are virtual filler clips** with their own timeline position and duration
2. **Adjacent clips are unaffected** by gap edge operations (only downstream clips shift)
3. **No media boundaries** since gap "source" is always 0 to duration
4. **Uniform algorithm** eliminates special cases and bugs

## Files Modified

- `src/lua/core/command_manager.lua` (lines 2351-2403): Gap materialization in BatchRippleEdit
- `test_ripple_operations.lua` (Tests 11-12): Gap edge test cases

## References

- Single RippleEdit already implemented gap materialization correctly (lines 1976-2040)
- BatchRippleEdit now uses same pattern for consistency
