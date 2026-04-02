# Quickstart Verification: Gap-as-Clip Refactor

## Automated Verification

```bash
# Full test suite (must pass with zero failures)
make -j4

# Specific multitrack ripple tests (27 tests, behavior unchanged)
cd tests && luajit test_harness.lua test_ripple_in_multitrack_upstream_stable.lua

# Gap lifecycle tests (new)
cd tests && luajit test_harness.lua test_gap_lifecycle.lua
```

## Manual Verification (in JVEEditor)

### 1. Clip-Gap Roll
- Open a sequence with two clips and a gap between them on V1
- Drag the left clip's out edge right (into the gap)
- **Verify**: left clip extends, gap shrinks, right clip stays put
- Undo. **Verify**: gap restored to original size

### 2. Clip-Gap Roll (E key)
- Place playhead inside the gap
- Select the left clip's out edge
- Press E (ExtendEdit)
- **Verify**: same result as mouse drag

### 3. Multitrack Ripple (with gap)
- Two clips on V1 with a gap. Audio on A1/A2 aligned with V1.
- Ripple-trim V1 left clip's out edge (shrink)
- **Verify**: gap grows, all downstream clips on all tracks shift left

### 4. Multitrack Ripple (blocked by zero gap)
- Adjacent clips on V1. Adjacent audio on A1/A2 (no gaps).
- Ripple-trim V1 left clip's out edge (shrink)
- **Verify**: operation blocked. Blocking edges shown red. Nothing moves.

### 5. Gap Split
- One large gap on V1
- Insert a clip in the middle of the gap
- **Verify**: two gaps appear, one on each side of the inserted clip

### 6. Gap Merge
- Three clips with gaps between them on V1
- Delete the middle clip
- **Verify**: two gaps merge into one

### 7. Gap Delete (trim to zero)
- Two clips with a small gap on V1
- Roll left clip's out edge right until gap closes
- **Verify**: gap disappears, clips are adjacent

### 8. Preview/Commit Consistency
- Drag a clip-gap roll slowly
- **Verify**: preview (rubber band) shows clip extending into gap, no ripple behavior
- Release mouse
- **Verify**: commit matches preview exactly
