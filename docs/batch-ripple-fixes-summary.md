# BatchRippleEdit Bug Fixes - Summary

## Date: 2025-10-12

## Files Modified
- `src/lua/core/command_manager.lua` (lines 2314-2555)

---

## Bug #1: Delta Negation (FIXED ✅)

### Problem
Code negated `delta_ms` for edges that differed from a "reference edge":
```lua
local reference_edge_type = edge_infos[1].edge_type  -- First edge clicked
local edge_delta = (actual_edge_type ~= reference_edge_type) and -delta_ms or delta_ms
```

**Impact**: Edges moved in wrong direction (extend instead of trim)

### Fix
Removed negation logic entirely:
```lua
local edge_delta = delta_ms  -- Same delta for ALL edges!
```

**Why this works**: `apply_edge_ripple()` already handles edge-type-specific behavior:
- In-point: `clip.duration -= delta_ms` (drag right = shrink)
- Out-point: `clip.duration += delta_ms` (drag right = grow)

---

## Bug #2: Incorrect Downstream Shift (FIXED ✅)

### Problem
Downstream clips were shifted by the drag delta captured from a single "winning" edge. When multiple ripple points existed, this caused two failures:

1. Clips located between earlier and later ripple points never moved, even though their upstream edits changed the timeline length.
2. Undo stored only one `shift_amount`, so it could never faithfully restore per-clip offsets once the operation became asymmetric.

### Fix
Model ripple edits as a set of **ripple events** and apply the cumulative shift for each downstream clip:

```lua
local ripple_events = {}

-- Phase 1: record every ripple point and its net shift contribution
table.insert(ripple_events, {
    time = ripple_time,
    shift = shift_for_this_edge  -- duration delta for that edge/gap
})

-- Phase 2: walk clips in start-time order and accumulate all events that
-- occur at or before the clip's start
local cumulative_shift = 0
while event_index <= #ripple_events and ripple_events[event_index].time <= clip.start_time do
    cumulative_shift = cumulative_shift + ripple_events[event_index].shift
    event_index = event_index + 1
end

if cumulative_shift ~= 0 then
    clip.start_time = clip.start_time + cumulative_shift
end
```

Undo now persists the exact `shift_amount` applied to each clip (`{clip_id, shift_amount}`), making the operation reversible regardless of how many ripple points are involved.

---

## Changes Made

### 1. Removed Reference Edge Type (Lines 2393-2461)
- Dropped the `reference_bracket` bookkeeping and the "negate delta for opposite edges" hack.
- Each edge now receives the same user drag delta; asymmetry stays localized inside `apply_edge_ripple`.

### 2. Fixed Delta Negation (Lines 2453-2461)
**Before:**
```lua
local edge_delta = (actual_edge_type ~= reference_edge_type) and -delta_ms or delta_ms
print(string.format("  Processing: clip=%s, actual_edge=%s, edge_delta=%d (negated=%s)",
    clip.id:sub(1,8), actual_edge_type, edge_delta,
    tostring(actual_edge_type ~= reference_edge_type)))
```

**After:**
```lua
-- BUG FIX: Pass same delta_ms to ALL edges - asymmetry comes from edge type, not negation
local edge_delta = delta_ms  -- Same delta for all edges!
print(string.format("  Processing: clip=%s, actual_edge=%s, edge_delta=%d",
    clip.id:sub(1,8), actual_edge_type, edge_delta))
```

### 3. Aggregate Ripple Events (Lines 2453-2521)
- Build `ripple_events` for every edge/gap.
- Merge events that occur at the same time (they cancel or compound).
- Sort clips by start time and accumulate shift as we cross each ripple point.
- Produce a deterministic `{clip_id, shift_amount}` list for preview, execution, and undo.

### 4. Dry-Run Preview (Lines 2521-2534)
- Preview now mirrors the execution path: clips are listed only when their cumulative shift is non-zero and use the same `clip_shift_lookup` values that execution applies.

### 5. Execution & Undo (Lines 2536-2588)
- Execution stores the exact per-clip shift list instead of a single scalar.
- Undo iterates over that list to reverse each movement.
- Success logging reports the number of downstream clips touched rather than a misleading "single shift" summary.

---

## Test Case: Asymmetric Ripple

**Setup:**
- Clip A: position=0ms, duration=1000ms
- Clip B: position=2000ms, duration=2000ms
- Select Clip A's out-point `]` and Clip B's in-point `[`
- Drag RIGHT +500ms

**Expected Behavior (BEFORE FIX):**
```
Clip A: edge_delta = +500 (reference edge)
  → duration += 500 = 1500ms ✓
  → ripple_time = 1500ms
  → shift = +500ms

Clip B: edge_delta = -500 (negated because in != out)
  → duration -= (-500) = duration += 500 = 2500ms ✗ WRONG!
  → ripple_time = 2000ms
  → shift = +500ms (uses delta_ms, ignores edge type)

Downstream clips: shift by +500ms ✗ WRONG!
```

**Actual Behavior (AFTER FIX):**
```
Clip A: shift contribution = +500ms at 1500ms
Clip B: shift contribution = -500ms at 2000ms

Downstream clips accumulate events in time order:
- Between 1500ms and 2000ms → net shift = +500ms
- At/after 2000ms           → net shift = 0ms
```

**Result**: Balanced asymmetric edits no longer disturb downstream clips, and multi-point trims during the same drag stay consistent across the entire timeline.

---

## Key Insights

1. **Asymmetry stays localized**: `apply_edge_ripple` already encapsulates in/out semantics, so the batch executor should never flip the user delta itself.

2. **Shift direction depends on edge type**:
   - In-point drag right = clip shrinks = timeline shifts LEFT (-delta)
   - Out-point drag right = clip grows = timeline shifts RIGHT (+delta)

3. **Cumulative timeline change matters**: Ripple edits can introduce multiple shift events; downstream clips must accumulate every prior event at or before their start time, not just the "last" one.

4. **Undo needs per-clip data**: Persisting `{clip_id, shift_amount}` keeps the event log reversible and ensures replays/undos match execution exactly.

---

## Remaining Work

✅ Multi-edge selection (ALREADY IMPLEMENTED)
✅ Cmd+click multi-select (ALREADY IMPLEMENTED)
✅ BatchRippleEdit command (NOW FIXED)
✅ Dry-run preview (NOW FIXED)
✅ Undo/redo (NOW FIXED)

🔲 Gap edge selection in UI (gaps materialized but not visually selectable)
🔲 Sync locks (track-level ripple protection)
🔲 Dynamic trimming (J-K-L playback with trim-on-stop)
🔲 Extract/Lift operations (ripple delete vs regular delete)
