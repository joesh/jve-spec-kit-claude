# Ripple Trim: Comprehensive Guide

## Table of Contents
1. [Core Concepts](#core-concepts)
2. [Single-Edge Ripple Trim](#single-edge-ripple-trim)
3. [Multi-Edge Ripple Trim](#multi-edge-ripple-trim)
4. [Asymmetric Ripple Trim](#asymmetric-ripple-trim)
5. [Gap/Filler Trimming](#gapfiller-trimming)
6. [Multi-Track Behavior](#multi-track-behavior)
7. [Constraint Resolution](#constraint-resolution)
8. [Professional NLE Patterns](#professional-nle-patterns)

---

## Core Concepts

### The Golden Rule of Ripple Trim
**A ripple trim NEVER moves the trimmed clip's position on the timeline.**

- The clip's `start_time` remains **absolutely fixed**
- Only `duration` and source media points (`source_in`/`source_out`) change
- **Downstream clips shift** to close/open the resulting gap

### Ripple vs Regular Trim

| Aspect | Ripple Trim | Regular Trim |
|--------|-------------|--------------|
| Trimmed clip position | FIXED | FIXED |
| Trimmed clip duration | Changes | Changes |
| Downstream clips | **Shift to close gap** | Stay in place (gap appears) |
| Gap creation | No (automatic closure) | Yes (manual gap) |

### Coordinate Systems

**Delta Space**: The amount the user drags the edge
- Positive delta = drag right
- Negative delta = drag left

**Shift Space**: The amount downstream clips move
- For **out-point** trim: `shift = +delta` (same direction)
- For **in-point** trim: `shift = -delta` (opposite direction)

This is because:
- Out-point drag right (+delta) → clip grows → pushes clips right (+shift)
- In-point drag right (+delta) → clip shrinks → pulls clips left (-shift)

---

## Single-Edge Ripple Trim

### In-Point Trim: Drag [ Right (+delta)

```
BEFORE:
┌───────────────────┐
│   Clip A          │
└───────────────────┘
position: 3618ms
duration: 3000ms
source_in: 0ms
source_out: 3000ms
```

**User drags [ right +500ms:**

```
AFTER:
     ┌──────────────┐
     │   Clip A     │
     └──────────────┘
position: 3618ms        ← UNCHANGED
duration: 2500ms        ← Reduced by 500ms
source_in: 500ms        ← Advanced by 500ms
source_out: 3000ms      ← Unchanged
```

**Effects:**
- Clip reveals **less** of beginning (skips first 500ms of media)
- Gap before clip **closes** by 500ms
- Downstream clips **shift left** by 500ms

**Code:**
```lua
if edge_type == "in" then
    clip.duration = clip.duration - delta_ms
    clip.source_in = clip.source_in + delta_ms
    -- start_time stays FIXED!

    -- Calculate ripple point and shift
    local ripple_point = clip.start_time
    local shift_amount = -delta_ms  -- opposite sign!
    shift_downstream_clips(ripple_point, shift_amount)
end
```

### In-Point Trim: Drag [ Left (-delta)

```
BEFORE:
     ┌──────────────┐
     │   Clip A     │
     └──────────────┘
position: 3618ms
duration: 2500ms
source_in: 500ms
source_out: 3000ms
```

**User drags [ left -500ms:**

```
AFTER:
┌───────────────────┐
│   Clip A          │
└───────────────────┘
position: 3618ms        ← UNCHANGED
duration: 3000ms        ← Increased by 500ms
source_in: 0ms          ← Rewound by 500ms
source_out: 3000ms      ← Unchanged
```

**Effects:**
- Clip reveals **more** of beginning (includes first 500ms of media)
- Gap before clip **opens** by 500ms
- Downstream clips **shift right** by 500ms

### Out-Point Trim: Drag ] Right (+delta)

```
BEFORE:
┌──────────────┐
│   Clip A     │
└──────────────┘
position: 3618ms
duration: 2500ms
source_in: 0ms
source_out: 2500ms
```

**User drags ] right +500ms:**

```
AFTER:
┌───────────────────┐
│   Clip A          │
└───────────────────┘
position: 3618ms        ← UNCHANGED
duration: 3000ms        ← Increased by 500ms
source_in: 0ms          ← Unchanged
source_out: 3000ms      ← Extended by 500ms
```

**Effects:**
- Clip reveals **more** of ending (includes 500ms more media)
- Gap after clip **closes** by 500ms
- Downstream clips **shift left** by 500ms

**Code:**
```lua
elseif edge_type == "out" then
    clip.duration = clip.duration + delta_ms
    clip.source_out = clip.source_in + clip.duration
    -- start_time stays FIXED!

    -- Calculate ripple point and shift
    local ripple_point = clip.start_time + clip.duration
    local shift_amount = delta_ms  -- same sign!
    shift_downstream_clips(ripple_point, shift_amount)
end
```

### Out-Point Trim: Drag ] Left (-delta)

```
BEFORE:
┌───────────────────┐
│   Clip A          │
└───────────────────┘
position: 3618ms
duration: 3000ms
source_in: 0ms
source_out: 3000ms
```

**User drags ] left -500ms:**

```
AFTER:
┌──────────────┐
│   Clip A     │
└──────────────┘
position: 3618ms        ← UNCHANGED
duration: 2500ms        ← Reduced by 500ms
source_in: 0ms          ← Unchanged
source_out: 2500ms      ← Trimmed by 500ms
```

**Effects:**
- Clip reveals **less** of ending (cuts off last 500ms)
- Gap after clip **opens** by 500ms
- Downstream clips **shift right** by 500ms

---

## Multi-Edge Ripple Trim

### Symmetric Multi-Edge (All Same Type)

When multiple edges of the **same type** are selected:

```
Track 1: [Clip A]     [Clip B]
Track 2: [Clip C]     [Clip D]
         ↑ both out-points selected
```

**User drags right +300ms:**
- Clip A extends by 300ms (duration += 300)
- Clip C extends by 300ms (duration += 300)
- All downstream clips shift right by 300ms

**Key Rule**: All edges move by the **same delta**, in the **same direction**.

### Selection Methods (Per NLE)

**Premiere Pro:**
- **Shift+click** each edge
- All selected edges highlighted
- Drag any selected edge to move all together

**Avid Media Composer:**
- **Lasso** around edit points to select multiple "rollers"
- **Alt+lasso** (Option+lasso) to access tracks below top track
- **Add Edit** command creates sync point across all tracks

**DaVinci Resolve:**
- Enter **Trim Mode** (T key)
- **Box select** around clips
- Press **U** to cycle which edge is active
- **Comma/period** for 1-frame nudges

---

## Asymmetric Ripple Trim

### Definition
**Asymmetric trim**: Multiple edges selected with a **mix of in-points and out-points** across different tracks.

### Critical Behavior Discovery

From Adobe Premiere Pro documentation:
> "When dragging an edit point right by 10 frames:
> - 10 frames are **added** to Ripple Out points
> - 10 frames are **subtracted** from Ripple In points"

This means:
- **Same user delta** (+10 frames right)
- **Opposite effect** based on edge type
- Out-point `]`: duration increases (clip grows)
- In-point `[`: duration decreases (clip shrinks)

### Example: Asymmetric Trim Right

```
BEFORE:
Track 1: [Clip A══════]   [Clip B══════]
                       ↑   ↑
                       ]   [ (both selected)
Track 2: [Clip C══════════════════════]
```

**User drags right +500ms:**

```
AFTER:
Track 1: [Clip A═════════]  [Clip B═══]
                         ↑   ↑
                         ]   [
Track 2: [Clip C══════════════════════]
         All clips shift right by net effect
```

**What happened:**
1. **Clip A out-point `]`**: duration += 500ms (extended)
2. **Clip B in-point `[`**: duration -= 500ms (trimmed)
3. Net timeline change = +500 - 500 = 0ms (no shift!)
4. If net ≠ 0, downstream clips shift by net amount

### Asymmetric Trim Formula

```lua
local total_shift = 0

for each selected_edge in selection do
    if selected_edge.type == "out" then
        -- Out-point: delta adds to duration
        clip.duration = clip.duration + delta_ms
        total_shift = total_shift + delta_ms
    elseif selected_edge.type == "in" then
        -- In-point: delta subtracts from duration
        clip.duration = clip.duration - delta_ms
        total_shift = total_shift - delta_ms
    end
end

-- Shift downstream clips by net effect
shift_downstream_clips(ripple_point, total_shift)
```

### Avid's Unique Asymmetric System

**Most Powerful Implementation** in the industry:

> "Avid's Asymmetrical trimming allows you to not only manually select the trim points for each track, but choose a **different side** of each point to trim."

**Roller Direction Rule:**
> "When you press the key to trim, everything with a roller on the **LEFT** will shorten the **END** of the shot, but everything with a roller on the **RIGHT** will shorten the **FRONT** of the shot."

**Workflow:**
1. Enter trim mode
2. Lasso or click to select edit points (creates "rollers")
3. Click left or right side of each roller to choose direction
4. Press [ or ] keys (or drag) to execute trim
5. **Alt+U** (Option+U) to re-enter with same roller config

---

## Gap/Filler Trimming

### Concept: Gap as Entity

**Critical Insight from Avid**: Empty timeline spaces are **not voids** — they're called **"filler"** and behave like clips with trimmable edges.

```
Timeline with gap:
[Clip A]  <--- 500ms gap --->  [Clip B]
        ]                      [
        ↑                      ↑
   Gap left edge          Gap right edge
```

### Gap Properties

A gap is defined by:
- **Start time**: Right edge of previous clip (or 0 if at timeline start)
- **Duration**: Time until next clip starts
- **Edges**:
  - **Left edge `]`**: Same as previous clip's out-point
  - **Right edge `[`**: Same as next clip's in-point

### Gap Trim Operations

**Trim gap's right edge right (+delta):**
- Same as ripple trim next clip's in-point right
- Gap duration increases by delta
- Next clip duration decreases by delta (reveals less of beginning)
- Downstream clips shift left

**Trim gap's right edge left (-delta):**
- Same as ripple trim next clip's in-point left
- Gap duration decreases by delta
- Next clip duration increases by delta (reveals more of beginning)
- Downstream clips shift right

**Trim gap's left edge right (+delta):**
- Same as ripple trim previous clip's out-point right
- Gap duration decreases by delta
- Previous clip duration increases by delta (reveals more of ending)
- Downstream clips shift left

**Trim gap's left edge left (-delta):**
- Same as ripple trim previous clip's out-point left
- Gap duration increases by delta
- Previous clip duration decreases by delta (reveals less of ending)
- Downstream clips shift right

### Gap Materialization for UI

```lua
-- Create virtual gap clips for rendering and selection
function materialize_gaps(clips)
    local entities = {}

    for i, clip in ipairs(clips) do
        table.insert(entities, clip)

        -- Check for gap after this clip
        local gap_start = clip.start_time + clip.duration
        local next_start = clips[i + 1] and clips[i + 1].start_time or math.huge

        if next_start > gap_start then
            local gap = {
                type = "gap",
                start_time = gap_start,
                duration = next_start - gap_start,
                track_id = clip.track_id,
                -- Gap edges map to adjacent clip edges
                left_edge_maps_to = {clip_id = clip.id, edge = "out"},
                right_edge_maps_to = {clip_id = clips[i + 1].id, edge = "in"}
            }
            table.insert(entities, gap)
        end
    end

    return entities
end
```

### Ripple Delete vs Lift

**Avid Operations:**

| Operation | Command | Behavior | Result |
|-----------|---------|----------|--------|
| **Extract** (Ripple Delete) | X key / Yellow scissors | Remove clip + close gap | No gap left |
| **Lift** (Non-Ripple Delete) | Z key / Red icon | Remove clip + leave filler | Gap remains |

**Extract = Ripple Trim Both Edges to Zero Duration**

```lua
-- Extract is equivalent to:
-- 1. Ripple trim in-point right by full duration
-- 2. This makes duration = 0
-- 3. Clip disappears, downstream shifts left

function extract_clip(clip)
    local full_duration = clip.duration
    ripple_trim_in_point(clip, full_duration)
    -- Clip now has 0ms duration (effectively deleted)
    -- Downstream clips shifted left by full_duration
end
```

---

## Multi-Track Behavior

### Cross-Track Ripple Rule

**Universal NLE Behavior**: Ripple operations affect **ALL downstream clips on ALL tracks**, not just the edited track.

```
BEFORE:
Track 1: [A════]    [B════]  [C════]
Track 2: [D════════]    [E════════]
                   ↑ ripple point at 2000ms
```

**Ripple trim at 2000ms with +500ms shift:**

```
AFTER:
Track 1: [A════]    [B════]       [C════]
Track 2: [D════════]    [E════════]
                        ↑ everything right of ripple point shifted
```

**Downstream Clip Definition:**
- Clip is downstream if `clip.start_time >= ripple_point`
- **All tracks** are checked, not just the trimmed clip's track
- Clips that overlap the ripple point are NOT shifted (they're stationary)

### Sync Locks (Protection Mechanism)

**Purpose**: Prevent unintended shifts on specific tracks during ripple operations.

**Premiere Pro:**
- Toggle sync lock icon on track header
- Locked tracks: clips do NOT shift during ripple
- Unlocked tracks: clips shift normally

**Avid:**
- Similar concept but different UI
- "Training wheels" for timeline management
- Helps maintain dialog sync during complex edits

### Implementation

```lua
function shift_downstream_clips(ripple_point, shift_amount, track_sync_locks)
    -- Get all clips across ALL tracks
    local all_clips = database:get_all_clips()

    for _, clip in ipairs(all_clips) do
        -- Check if track is sync-locked
        local track_locked = track_sync_locks[clip.track_id] or false

        -- Shift if downstream and not locked
        if clip.start_time >= ripple_point and not track_locked then
            clip.start_time = clip.start_time + shift_amount
        end
    end
end
```

---

## Constraint Resolution

### Single-Edge Constraints

For a single ripple trim, constraints come from:

1. **Adjacent clips** (collision prevention)
2. **Minimum duration** (clip must be ≥ 1ms)
3. **Media boundaries** (can't trim beyond source_in = 0 or source_out = media.duration)
4. **Timeline boundaries** (can't shift clips before t = 0)
5. **Frame alignment** (must snap to frame boundaries)

### Multi-Edge Constraints

With asymmetric selection, constraints are **per-edge** and must be **combined**:

```lua
function calculate_asymmetric_constraints(selected_edges, proposed_delta)
    local min_allowed_delta = -math.huge
    local max_allowed_delta = math.huge

    for _, edge_info in ipairs(selected_edges) do
        local clip = edge_info.clip
        local edge_type = edge_info.edge_type

        -- Calculate constraints for this specific edge
        local edge_min, edge_max = calculate_trim_range(clip, edge_type)

        -- For in-points, delta subtracts from duration
        -- So we need to flip the constraint logic
        if edge_type == "in" then
            -- In-point right (+delta) shrinks clip (limit: duration - 1ms)
            -- In-point left (-delta) grows clip (limit: source_in)
            edge_min = -(clip.duration - 1)  -- max shrink
            edge_max = clip.source_in         -- max grow
        else
            -- Out-point right (+delta) grows clip
            -- Out-point left (-delta) shrinks clip
            edge_min = -(clip.duration - 1)  -- max shrink
            edge_max = clip.media.duration - (clip.source_in + clip.duration)  -- max grow
        end

        -- Combine constraints (most restrictive wins)
        min_allowed_delta = math.max(min_allowed_delta, edge_min)
        max_allowed_delta = math.min(max_allowed_delta, edge_max)
    end

    -- Clamp proposed delta to valid range
    local clamped_delta = math.max(min_allowed_delta,
                                   math.min(max_allowed_delta, proposed_delta))

    return clamped_delta
end
```

### Contradictory Constraints

**Problem**: With asymmetric selection, constraints can conflict.

**Example:**
- Edge A (out-point): Can extend max 200ms
- Edge B (in-point): Can trim max 100ms
- User drags right +300ms

**Resolution**:
```lua
-- Edge A wants: +300ms (clamped to +200ms)
-- Edge B wants: +300ms in delta, but -300ms in effect (clamped to -100ms)
-- Net effect: +200ms - 100ms = +100ms shift

-- Final result:
-- Edge A extends by +200ms (hit limit)
-- Edge B trims by -100ms (hit limit)
-- Downstream shifts right by +100ms
```

---

## Professional NLE Patterns

### Dynamic Trimming (J-K-L Method)

**Workflow** (supported by Premiere, Avid, FCP):

1. **Enter trim mode**:
   - Double-click edit point, OR
   - Press **T** key (Premiere), OR
   - Select trim tool and click

2. **Use J-K-L keys**:
   - **L**: Play forward (1x, 2x, 3x speed with multiple presses)
   - **J**: Play backward (1x, 2x, 3x speed with multiple presses)
   - **K**: Stop playback

3. **Execute trim**:
   - Press **K** to stop at desired frame
   - Trim is applied at current playhead position
   - OR: Hold **K** and tap **J/L** for frame-by-frame

4. **Adjust**:
   - Continue playing with **J/L** to preview
   - Press **K** again to re-trim
   - Exit trim mode when satisfied

**Advantage**: Real-time preview of content flow before committing edit.

### Keyboard Shortcuts (Premiere Pro)

| Shortcut | Action |
|----------|--------|
| **Q** | Ripple trim start of clip (no gap) |
| **W** | Ripple trim end of clip (no gap) |
| **Alt+Q** (Win) / **Opt+Q** (Mac) | Regular trim start (leaves gap) |
| **Alt+W** (Win) / **Opt+W** (Mac) | Regular trim end (leaves gap) |
| **Shift+Q** | Extend previous edit to playhead |
| **Shift+W** | Extend next edit to playhead |
| **T** | Enter/exit trim mode |
| **Shift+T** | Toggle trim mode |

### Avid Trim Mode Persistence

**Alt+U (Option+U) Shortcut**:
> "Re-enter Trim Mode with the Trim Roller configuration that was last used."

**Use Case**: When you've set up a complex asymmetric trim (e.g., 8 tracks with different roller sides), you can:
1. Execute the trim
2. Exit trim mode to review
3. Press **Alt+U** to re-enter with **exact same roller setup**
4. Make fine adjustments without re-selecting all rollers

---

## Summary: Implementation Checklist

### ✅ Already Implemented (Per CLAUDE.md)
- [x] Single-edge ripple trim (in-point and out-point)
- [x] Constraint system (adjacent clips, duration, media boundaries)
- [x] Cross-track collision detection
- [x] Gap materialization for constraints
- [x] Frame snapping
- [x] Deterministic replay (clamped delta stored)

### ⚠️ Partially Implemented
- [ ] **Gap edge selection** (gaps materialized for constraints but not selectable in UI)
- [ ] **Gap visual rendering** (gaps exist but may not show as trimmable entities)

### ❌ Not Yet Implemented
- [ ] **Multi-edge selection** (selecting multiple edges simultaneously)
- [ ] **Asymmetric ripple trim** (mixed in-point/out-point selection)
- [ ] **Symmetric multi-edge trim** (all same type)
- [ ] **Per-edge constraint resolution** (combining constraints from multiple edges)
- [ ] **Sync locks** (protecting specific tracks from ripple shifts)
- [ ] **Extract/Lift operations** (ripple delete vs non-ripple delete)
- [ ] **Dynamic trimming** (J-K-L playback with trim-on-stop)

---

## References

### Documentation Sources
- Adobe Premiere Pro: Trim Mode Editing (helpx.adobe.com)
- Avid Media Composer: Editing Guide 2020.6 (resources.avid.com)
- DaVinci Resolve: Ripple Trim Tutorial (dvresolve.com)
- Frame.io Blog: Sync Locks in Avid and Premiere (blog.frame.io)
- PremiumBeat: JKL Timeline Trimming (premiumbeat.com)

### Key Quotes

**Premiere Pro on Asymmetric Trimming:**
> "When a combination of Ripple In and Ripple Out edit points are selected on different tracks, with one edit point selected per track, it's an asymmetrical trim. The trim duration is the same on all tracks for each asymmetrical trim operation, but the direction of each edit point trims left or right may differ."

**Avid on Asymmetric Trimming:**
> "This Asymmetrical Trimming is unique to Avid, and other NLEs have nothing even close to this ability."

**On Gap Handling:**
> "In Avid, when you delete a segment from a sequence, blank space or filler is left in its place. Filler is intended to add empty space inside an existing video track—to create a black hole in between two other shots."
