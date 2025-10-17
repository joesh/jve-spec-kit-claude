# BatchRippleEdit Bugs

## Bug Analysis: Incorrect Asymmetric Ripple Implementation

### Current Implementation

File: `src/lua/core/command_manager.lua` lines 2314-2498

The `BatchRippleEdit` command attempts to handle multi-edge ripple operations but has fundamental flaws in its asymmetric trimming logic.

---

## Bug #1: Delta Negation Logic (Line 2394)

### The Code

```lua
-- Line 2338-2346: Determine reference edge
local reference_edge_type = edge_infos[1].edge_type
if reference_edge_type == "gap_after" then
    reference_edge_type = "out"
elseif reference_edge_type == "gap_before" then
    reference_edge_type = "in"
end

-- Line 2391-2396: Apply edge ripple with delta negation
local edge_delta = (actual_edge_type ~= reference_edge_type) and -delta_ms or delta_ms
```

### The Problem

**The code negates delta for edges that differ from the "reference edge" (first edge in array).**

This is fundamentally wrong because:
1. Whether to negate depends on which edge happened to be clicked first
2. It doesn't understand the actual semantics of in-point vs out-point ripple

### How `apply_edge_ripple` Actually Works

The `apply_edge_ripple` function (lines 1854-1952) already handles edge-type-specific behavior:

**For in-point trims** (line 1875):
```lua
clip.duration = clip.duration - delta_ms
```
- Positive delta (+500) = drag right → duration shrinks → clip reveals less of beginning
- Negative delta (-500) = drag left → duration grows → clip reveals more of beginning

**For out-point trims** (line 1913):
```lua
clip.duration = clip.duration + delta_ms
```
- Positive delta (+500) = drag right → duration grows → clip reveals more of ending
- Negative delta (-500) = drag left → duration shrinks → clip reveals less of ending

**The asymmetry is BUILT IN to `apply_edge_ripple`!** All edges should receive the SAME delta value.

### Test Case: Wrong Behavior

**Setup:**
- Clip A: duration = 3000ms
- Clip B: duration = 3000ms
- Select Clip A's out-point `]` and Clip B's in-point `[`
- Drag RIGHT +500ms

**Expected (from NLE research):**
- Clip A out-point: duration += 500ms → 3500ms (extends)
- Clip B in-point: duration -= 500ms → 2500ms (trims)
- Net shift: +500ms (A grows) + (-500ms) (B shrinks from beginning) = 0ms
- Downstream clips: NO SHIFT (balanced edit)

**Current buggy behavior:**
```lua
reference_edge_type = "out"  -- First edge in array

// Edge A (out-point)
actual_edge_type = "out"
edge_delta = (out != out) ? -500 : +500 = +500  ✓ correct
apply_edge_ripple(clip_a, "out", +500)
  → clip_a.duration += 500  ✓ 3000 → 3500

// Edge B (in-point)
actual_edge_type = "in"
edge_delta = (in != out) ? -500 : +500 = -500  ✗ WRONG!
apply_edge_ripple(clip_b, "in", -500)
  → clip_b.duration -= (-500) = clip_b.duration += 500  ✗ 3000 → 3500!
```

**Result**: Clip B EXTENDS instead of TRIMMING! Both clips grow by 500ms!

### Correct Behavior

**Don't negate delta - pass same delta to all edges:**

```lua
// Edge A (out-point)
edge_delta = +500  ✓ Same for all edges
apply_edge_ripple(clip_a, "out", +500)
  → clip_a.duration += 500  ✓ 3000 → 3500

// Edge B (in-point)
edge_delta = +500  ✓ Same for all edges
apply_edge_ripple(clip_b, "in", +500)
  → clip_b.duration -= 500  ✓ 3000 → 2500
```

---

## Bug #2: Incorrect Downstream Shift Calculation (Lines 2459, 2476)

### The Code

```lua
-- Line 2459 (dry run preview)
new_start_time = downstream_clip.start_time + delta_ms

-- Line 2476 (actual execution)
shift_clip.start_time = shift_clip.start_time + delta_ms
```

### The Problem

**The code shifts downstream clips by the user's drag delta (`delta_ms`), not the NET timeline change.**

With asymmetric trimming, multiple edges can have OPPOSITE effects on timeline duration:
- Out-point extending = pushes timeline right
- In-point trimming from beginning = pulls timeline left
- Net effect might be ZERO!

### Test Case: Wrong Behavior

**Setup (same as above):**
- Clip A out-point `]` + Clip B in-point `[`
- Drag RIGHT +500ms

**Expected downstream shift:**
- Clip A extends by 500ms at its out-point (ripple point = 1500ms)
- Clip B shrinks by 500ms at its in-point (ripple point = 3000ms)
- Latest ripple point = 3000ms (Clip B's position)
- Net shift at 3000ms = 0ms (balanced)
- Downstream clips: NO MOVEMENT

**Current buggy behavior:**
```lua
// Phase 1: Trim both edges (BUG #1 causes wrong trim, but let's assume it's fixed)
ripple_time_A = 1500ms (Clip A's out-point)
ripple_time_B = 3000ms (Clip B's in-point)
latest_ripple_time = 3000ms  ✓ Correct

// Phase 2: Shift downstream clips
for all clips starting at >= 3000ms:
    clip.start_time += delta_ms  ✗ WRONG!
    clip.start_time += 500ms
```

**Result**: Downstream clips shift RIGHT by 500ms even though net timeline change is 0ms!

### Correct Behavior

**Calculate actual shift from edge changes:**

```lua
-- Track ripple shifts per edge during Phase 1
local ripple_shifts = {}

for each edge:
    local old_duration = clip.duration
    apply_edge_ripple(clip, edge_type, delta_ms)
    local new_duration = clip.duration

    local ripple_time
    local shift_amount
    if edge_type == "in" then
        ripple_time = clip.start_time
        shift_amount = -(new_duration - old_duration)  -- opposite sign!
    else -- edge_type == "out"
        ripple_time = clip.start_time + new_duration
        shift_amount = (new_duration - old_duration)  -- same sign
    end

    table.insert(ripple_shifts, {
        time = ripple_time,
        shift = shift_amount
    })
end

-- Find latest ripple point and its shift
local latest_shift = 0
local latest_time = 0
for _, rs in ipairs(ripple_shifts) do
    if rs.time > latest_time then
        latest_time = rs.time
        latest_shift = rs.shift
    end
end

-- Phase 2: Shift downstream by ACTUAL shift amount
for all clips starting at >= latest_time:
    clip.start_time += latest_shift  ✓ Correct!
```

In our test case:
- Edge A: ripple_time=1500ms, shift=+500ms (grows)
- Edge B: ripple_time=3000ms, shift=-500ms (shrinks from beginning)
- Latest: time=3000ms, shift=-500ms
- Downstream clips shift LEFT by 500ms ✓ Correct!

Wait, that's still not quite right... Let me think more carefully.

Actually, the issue is more subtle. When multiple edges are trimmed:

**Clip A out-point extends by 500ms:**
- Clip A duration: 1000ms → 1500ms
- Clip A position: FIXED at 0ms (ripple rule!)
- Ripple point: 0ms + 1500ms = 1500ms
- Clips starting after 1500ms shift RIGHT by +500ms

**Clip B in-point trims by 500ms:**
- Clip B duration: 2000ms → 1500ms
- Clip B position: FIXED at 2000ms (ripple rule!)
- Ripple point: 2000ms
- Clips starting after 2000ms shift LEFT by -500ms

**Conflict**: Clips between 1500ms and 2000ms get TWO shift commands!
- From Edge A: shift right +500ms
- From Edge B: shift left -500ms
- Net: 0ms shift

**The real fix**: Process ripples in order and accumulate shifts!

Actually, I think the intended behavior in BatchRippleEdit is to find the SINGLE latest ripple point and shift from there. But the shift amount is still wrong.

Let me reconsider... In professional NLEs, when you select multiple edges and drag:
- ALL edges move by the same pixel amount
- The timeline shifts to accommodate the NET change
- The shift happens at the RIGHTMOST affected point

For asymmetric with Clip A ] and Clip B [:
- Both edges dragged right +500ms
- Clip A grows (out-point extends)
- Clip B shrinks (in-point trims)
- Rightmost ripple point is Clip B's position
- At that point, Clip A's change has already happened (it's earlier on timeline)
- The shift at Clip B's point is just Clip B's effect: -500ms (shrink)

Hmm, but this doesn't match how single ripples work... Let me look at single RippleEdit again.

### Root Cause Analysis

Looking at single `RippleEdit` (lines 2206-2214):

```lua
if edge_type == "in" then
    shift_amount = -delta_ms  -- In-point: opposite direction
else  -- edge_type == "out"
    shift_amount = delta_ms   -- Out-point: same direction
end
```

This is correct! **The shift direction depends on edge TYPE, not on negating delta.**

### The Correct Fix

**Phase 1: Remove delta negation** (line 2394):

```lua
-- BEFORE (WRONG):
local edge_delta = (actual_edge_type ~= reference_edge_type) and -delta_ms or delta_ms

-- AFTER (CORRECT):
local edge_delta = delta_ms  -- Same delta for ALL edges
```

**Phase 2: Calculate shift from edge type** (add after line 2397):

```lua
-- Track rightmost ripple and its shift amount
local latest_ripple_time = 0
local latest_shift_amount = 0

for each edge:
    local ripple_time, success = apply_edge_ripple(clip, actual_edge_type, delta_ms)

    -- Calculate shift for this specific edge
    local shift_for_this_edge
    if actual_edge_type == "in" then
        shift_for_this_edge = -delta_ms  -- In-point: opposite
    else  -- "out"
        shift_for_this_edge = delta_ms   -- Out-point: same
    end

    -- Track rightmost ripple point and its shift
    if ripple_time and ripple_time > latest_ripple_time then
        latest_ripple_time = ripple_time
        latest_shift_amount = shift_for_this_edge
    end
end

-- Phase 2: Use calculated shift, not raw delta
for downstream clips:
    clip.start_time += latest_shift_amount  -- NOT delta_ms!
```

---

## Summary

**Two critical bugs in BatchRippleEdit:**

1. **Line 2394**: Negates delta for opposite-type edges
   - **Impact**: Edges move in wrong direction (extend instead of trim)
   - **Fix**: Remove negation, pass same `delta_ms` to all edges

2. **Lines 2459, 2476**: Uses `delta_ms` for downstream shift
   - **Impact**: Incorrect timeline shift with asymmetric selection
   - **Fix (final)**: Aggregate every ripple point, sort by time, and apply the cumulative shift for each downstream clip. The "rightmost wins" intuition was a useful debugging step, but the production fix accumulates all prior events.

**Why these bugs exist:**
- Misunderstanding of how `apply_edge_ripple` handles edge types
- Trying to implement asymmetry at wrong layer (BatchRippleEdit instead of apply_edge_ripple)
- Not accounting for different shift directions based on edge type

**The correct mental model:**
- `apply_edge_ripple`: Knows edge semantics (in vs out)
- `delta_ms`: Always the same for all edges (user's drag distance)
- Asymmetry emerges from edge type, not from negating delta!
