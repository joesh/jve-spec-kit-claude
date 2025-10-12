# Ripple Trim Semantics

## Critical Rule
**RIPPLE TRIM NEVER MOVES THE TRIMMED CLIP'S POSITION**
Only duration and source media change. Downstream clips shift to close/open the gap.

---

## Ripple In-Point Trim (drag [ bracket right)

### Scenario: Drag in-point right +500ms

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

### User Action: Drag [ right +500ms (delta_ms = +500)

```
AFTER:
     ┌──────────────┐
     │   Clip A     │
     └──────────────┘
position: 3618ms        ← UNCHANGED!
duration: 2500ms        ← Reduced by 500ms
source_in: 500ms        ← Advanced by 500ms
source_out: 3000ms      ← Unchanged (out-point not trimmed)
```

### Code Logic:
```lua
if edge_type == "in" then
    -- BEFORE: start=3618, dur=3000, src_in=0
    -- AFTER:  start=3618, dur=2500, src_in=500

    clip.duration = clip.duration - delta_ms  -- 3000 - 500 = 2500
    clip.source_in = clip.source_in + delta_ms  -- 0 + 500 = 500
    -- DO NOT MODIFY clip.start_time!
end
```

### Key Points:
- ✅ Position stays at 3618ms
- ✅ Duration shrinks to 2500ms
- ✅ Source media advances to 500ms (reveal less of the beginning)
- ✅ Gap before clip closes by 500ms
- ✅ Downstream clips shift left by 500ms

---

## Ripple In-Point Trim (drag [ bracket left)

### Scenario: Drag in-point left -500ms

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

### User Action: Drag [ left -500ms (delta_ms = -500)

```
AFTER:
┌───────────────────┐
│   Clip A          │
└───────────────────┘
position: 3618ms        ← UNCHANGED!
duration: 3000ms        ← Increased by 500ms
source_in: 0ms          ← Rewound by 500ms
source_out: 3000ms      ← Unchanged
```

### Code Logic:
```lua
if edge_type == "in" then
    -- BEFORE: start=3618, dur=2500, src_in=500
    -- AFTER:  start=3618, dur=3000, src_in=0

    clip.duration = clip.duration - delta_ms  -- 2500 - (-500) = 3000
    clip.source_in = clip.source_in + delta_ms  -- 500 + (-500) = 0
    -- DO NOT MODIFY clip.start_time!
end
```

### Key Points:
- ✅ Position stays at 3618ms
- ✅ Duration grows to 3000ms
- ✅ Source media rewinds to 0ms (reveal more of the beginning)
- ✅ Gap before clip opens by 500ms
- ✅ Downstream clips shift right by 500ms

---

## Ripple Out-Point Trim (drag ] bracket right)

### Scenario: Drag out-point right +500ms

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

### User Action: Drag ] right +500ms (delta_ms = +500)

```
AFTER:
┌───────────────────┐
│   Clip A          │
└───────────────────┘
position: 3618ms        ← UNCHANGED!
duration: 3000ms        ← Increased by 500ms
source_in: 0ms          ← Unchanged (in-point not trimmed)
source_out: 3000ms      ← Extended by 500ms
```

### Code Logic:
```lua
elseif edge_type == "out" then
    -- BEFORE: start=3618, dur=2500, src_out=2500
    -- AFTER:  start=3618, dur=3000, src_out=3000

    clip.duration = clip.duration + delta_ms  -- 2500 + 500 = 3000
    clip.source_out = clip.source_in + clip.duration  -- 0 + 3000 = 3000
    -- DO NOT MODIFY clip.start_time!
end
```

### Key Points:
- ✅ Position stays at 3618ms
- ✅ Duration grows to 3000ms
- ✅ Source media extends to 3000ms (reveal more of the end)
- ✅ Gap after clip closes by 500ms
- ✅ Downstream clips shift left by 500ms

---

## Ripple Out-Point Trim (drag ] bracket left)

### Scenario: Drag out-point left -500ms

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

### User Action: Drag ] left -500ms (delta_ms = -500)

```
AFTER:
┌──────────────┐
│   Clip A     │
└──────────────┘
position: 3618ms        ← UNCHANGED!
duration: 2500ms        ← Reduced by 500ms
source_in: 0ms          ← Unchanged (in-point not trimmed)
source_out: 2500ms      ← Trimmed by 500ms
```

### Code Logic:
```lua
elseif edge_type == "out" then
    -- BEFORE: start=3618, dur=3000, src_out=3000
    -- AFTER:  start=3618, dur=2500, src_out=2500

    clip.duration = clip.duration + delta_ms  -- 3000 + (-500) = 2500
    clip.source_out = clip.source_in + clip.duration  -- 0 + 2500 = 2500
    -- DO NOT MODIFY clip.start_time!
end
```

### Key Points:
- ✅ Position stays at 3618ms
- ✅ Duration shrinks to 2500ms
- ✅ Source media trims to 2500ms (reveal less of the end)
- ✅ Gap after clip opens by 500ms
- ✅ Downstream clips shift right by 500ms

---

## Common Mistake

### ❌ WRONG: Moving the clip position
```lua
if edge_type == "in" then
    clip.start_time = clip.start_time + delta_ms  -- ❌ NEVER DO THIS!
    clip.duration = clip.duration - delta_ms
end
```

This causes the clip to "slide" along the timeline, which is NOT ripple trim behavior.

### ✅ CORRECT: Keep position fixed
```lua
if edge_type == "in" then
    -- Position stays FIXED at original value
    clip.duration = clip.duration - delta_ms
    clip.source_in = clip.source_in + delta_ms
end
```

---

## Ripple vs Regular Trim

| Operation | Trimmed Clip Position | Trimmed Clip Duration | Downstream Clips |
|-----------|----------------------|----------------------|------------------|
| **Ripple Trim** | FIXED | Changes | Shift to close gap |
| **Regular Trim** | FIXED | Changes | Stay in place (gap appears) |

The difference: Ripple trim shifts downstream clips, regular trim doesn't.

---

## Validation Tests

To verify ripple trim works correctly, check these assertions after execution:

```lua
-- In-point trim: position must NOT change
local original_position = clip.start_time
apply_in_point_ripple(clip, delta_ms)
assert(clip.start_time == original_position, "BUG: Position changed!")

-- Out-point trim: position must NOT change
local original_position = clip.start_time
apply_out_point_ripple(clip, delta_ms)
assert(clip.start_time == original_position, "BUG: Position changed!")
```
