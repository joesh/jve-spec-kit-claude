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
Code shifted downstream clips by raw `delta_ms`:
```lua
shift_clip.start_time = shift_clip.start_time + delta_ms
```

**Impact**: With asymmetric selection, downstream shift ignored edge type differences

### Fix
Calculate shift from rightmost edge's type:
```lua
-- Track shift during Phase 1
local latest_shift_amount = 0

for each edge:
    local shift_for_this_edge
    if actual_edge_type == "in" then
        shift_for_this_edge = -edge_delta  -- Opposite direction
    else  -- "out"
        shift_for_this_edge = edge_delta   -- Same direction
    end

    if ripple_time > latest_ripple_time then
        latest_ripple_time = ripple_time
        latest_shift_amount = shift_for_this_edge
    end
end

-- Phase 2: Use calculated shift
shift_clip.start_time = shift_clip.start_time + latest_shift_amount
```

---

## Changes Made

### 1. Removed Reference Edge Type (Lines 2329-2346)
**Before:**
```lua
local original_states = {}
local latest_ripple_time = 0
local preview_affected_clips = {}

local reference_edge_type = edge_infos[1].edge_type
if reference_edge_type == "gap_after" then
    reference_edge_type = "out"
elseif reference_edge_type == "gap_before" then
    reference_edge_type = "in"
end

print(string.format("DEBUG BatchRippleEdit: %d edges, delta_ms=%d, reference_edge=%s",
    #edge_infos, delta_ms, reference_edge_type))
```

**After:**
```lua
local original_states = {}
local latest_ripple_time = 0
local latest_shift_amount = 0  -- Track shift for downstream clips
local preview_affected_clips = {}

print(string.format("DEBUG BatchRippleEdit: %d edges, delta_ms=%d",
    #edge_infos, delta_ms))
```

### 2. Fixed Delta Negation (Lines 2382-2388)
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

### 3. Track Shift Amount (Lines 2412-2432)
**Before:**
```lua
-- Track latest ripple point
if ripple_time and ripple_time > latest_ripple_time then
    latest_ripple_time = ripple_time
end
```

**After:**
```lua
-- Track latest ripple point and its shift amount
-- BUG FIX: Calculate shift based on edge type, not raw delta
if ripple_time then
    local shift_for_this_edge
    if actual_edge_type == "in" then
        shift_for_this_edge = -edge_delta  -- Opposite direction
    else  -- "out"
        shift_for_this_edge = edge_delta   -- Same direction
    end

    -- Use the rightmost ripple point's shift
    if ripple_time > latest_ripple_time then
        latest_ripple_time = ripple_time
        latest_shift_amount = shift_for_this_edge
        print(string.format("  New latest ripple: time=%dms, shift=%dms (edge_type=%s)",
            latest_ripple_time, latest_shift_amount, actual_edge_type))
    end
end
```

### 4. Fixed Dry-Run Preview Shift (Line 2466)
**Before:**
```lua
new_start_time = downstream_clip.start_time + delta_ms
```

**After:**
```lua
new_start_time = downstream_clip.start_time + latest_shift_amount  -- BUG FIX: Use calculated shift
```

### 5. Fixed Execution Shift (Line 2483)
**Before:**
```lua
shift_clip.start_time = shift_clip.start_time + delta_ms
```

**After:**
```lua
shift_clip.start_time = shift_clip.start_time + latest_shift_amount  -- BUG FIX: Use calculated shift
```

### 6. Store Shift for Undo (Line 2500)
**Added:**
```lua
command:set_parameter("shift_amount", latest_shift_amount)  -- Store calculated shift for undo
```

### 7. Enhanced Success Message (Line 2502)
**Before:**
```lua
print(string.format("✅ Batch ripple: trimmed %d edges by %dms, shifted %d downstream clips",
    #edge_infos, delta_ms, #clips_to_shift))
```

**After:**
```lua
print(string.format("✅ Batch ripple: trimmed %d edges by %dms, shifted %d downstream clips by %dms",
    #edge_infos, delta_ms, #clips_to_shift, latest_shift_amount))
```

### 8. Fixed Undo Shift (Lines 2513, 2547)
**Before:**
```lua
local delta_ms = command:get_parameter("delta_ms")
...
shift_clip.start_time = shift_clip.start_time - delta_ms
```

**After:**
```lua
local shift_amount = command:get_parameter("shift_amount")  -- BUG FIX: Use stored shift, not delta_ms
...
shift_clip.start_time = shift_clip.start_time - shift_amount  -- BUG FIX: Use stored shift
```

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
Clip A: edge_delta = +500 (same for all)
  → duration += 500 = 1500ms ✓
  → ripple_time = 1500ms
  → shift_for_this_edge = +500ms (out-point: same direction)

Clip B: edge_delta = +500 (same for all)
  → duration -= 500 = 1500ms ✓ CORRECT!
  → ripple_time = 2000ms
  → shift_for_this_edge = -500ms (in-point: opposite direction)

Latest: ripple_time = 2000ms, shift = -500ms

Downstream clips: shift by -500ms ✓ CORRECT!
```

**Result**: Balanced asymmetric edit works correctly!

---

## Key Insights

1. **Asymmetry is built into `apply_edge_ripple`**: The function already knows how to handle in-point vs out-point differently. We don't need to negate delta.

2. **Shift direction depends on edge type**:
   - In-point drag right = clip shrinks = timeline shifts LEFT (-delta)
   - Out-point drag right = clip grows = timeline shifts RIGHT (+delta)

3. **Rightmost ripple wins**: With multiple edges, use the shift amount from the rightmost (latest) ripple point for downstream clips.

4. **Undo must use calculated shift**: Can't reconstruct shift from delta_ms alone - must store it during execution.

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
