# 03-CORE-INVARIANTS

## Purpose
This document catalogs immutable system properties that MUST hold at all times. Violations trigger assertions (development) or undefined behavior (production). Reference: ENGINEERING.md §1.14 (Fail-Fast Assert Policy).

---

## INV-001: Timebase Integrity
**Statement**: All time values are represented as rational numbers `{frames, fps_numerator, fps_denominator}` where numerator > 0, denominator > 0, frames is integer.

**Evidence**:
- `src/lua/core/rational.lua:14-32` - `validate_inputs()` enforces positive integers
- `src/lua/schema.sql:38-42` - `media.fps_numerator`, `media.fps_denominator` have `CHECK` constraints
- `src/lua/schema.sql:147-149` - `clips.fps_numerator`, `clips.fps_denominator` have `CHECK` constraints

**How to Verify**:
```lua
-- Positive test
local r = Rational.new(100, 24, 1)  -- OK
local r = Rational.new(100, 24000, 1001)  -- OK

-- Negative test (should error)
local r = Rational.new(100.5, 24, 1)  -- Error: frames must be integer
local r = Rational.new(100, -24, 1)   -- Error: fps_numerator must be positive
local r = Rational.new(100, 24, 0)    -- Error: fps_denominator must be positive
```

**Related Rules**: ENGINEERING.md §1.1 (fail fast), §2.13 (no fallbacks)

---

## INV-002: No Floating-Point Time
**Statement**: Time calculations NEVER use floating-point arithmetic for timeline positions. Floats are only used for final display conversion (pixels, timecode).

**Evidence**:
- `src/lua/core/rational.lua:80-89` - `rescale()` uses integer math + floor
- `src/lua/core/rational.lua:54-70` - `from_seconds()` marked "UI helper only"
- `src/lua/core/frame_utils.lua` - All frame utilities return integers

**How to Verify**:
```lua
-- Database stores integers
SELECT timeline_start_frame, duration_frames FROM clips;
-- Result: 0, 100 (not 0.0, 4.166666)

-- Rescaling preserves precision
local r1 = Rational.new(100, 24, 1)
local r2 = r1:rescale(30, 1)
assert(r2.frames == 125)  -- Not 125.0 or 124.99999
```

**Related Rules**: ENGINEERING.md §1.1 (error handling), docs/RIPPLE-ALGORITHM-RULES.md (gap handling)

---

## INV-003: Video Track No-Overlap
**Statement**: On VIDEO tracks, clips cannot overlap in time. Audio tracks MAY overlap (mix behavior).

**Evidence**:
- `src/lua/schema.sql:254-277` - Trigger `trg_prevent_video_overlap_insert`
- `src/lua/schema.sql:280-303` - Trigger `trg_prevent_video_overlap_update`
- Both triggers check `track_type = 'VIDEO'` and raise `ABORT` on overlap

**How to Verify**:
```sql
-- Insert clip on video track at 0-100
INSERT INTO clips (id, track_id, timeline_start_frame, duration_frames, ...) 
VALUES ('c1', 'v1', 0, 100, ...);

-- Attempt overlapping clip at 50-150 (should fail)
INSERT INTO clips (id, track_id, timeline_start_frame, duration_frames, ...) 
VALUES ('c2', 'v1', 50, 100, ...);
-- Result: ABORT, VIDEO_OVERLAP error

-- Adjacent clips OK
INSERT INTO clips (id, track_id, timeline_start_frame, duration_frames, ...) 
VALUES ('c3', 'v1', 100, 100, ...);
-- Result: Success
```

**Related Rules**: ENGINEERING.md §1.12 (external input validation), §1.14 (DB as internal state)

---

## INV-004: Command Sequencing
**Statement**: All commands have monotonically increasing `sequence_number`. Undo/redo position (`current_sequence_number`) is always ≤ max sequence number.

**Evidence**:
- `src/lua/core/command_history.lua:53-59` - Loads `MAX(sequence_number)` on init
- `src/lua/core/command_history.lua:101-108` - Increments `last_sequence_number` on record
- `src/lua/schema.sql:174` - `sequence_number INTEGER NOT NULL UNIQUE`

**How to Verify**:
```lua
-- Execute commands
command_manager.execute(cmd1)  -- sequence_number = 1
command_manager.execute(cmd2)  -- sequence_number = 2
command_manager.execute(cmd3)  -- sequence_number = 3

-- Verify monotonic increase
SELECT sequence_number FROM commands ORDER BY sequence_number;
-- Result: 1, 2, 3 (no gaps, duplicates, or decreases)

-- Undo moves position backward
command_history.undo()  -- current_sequence_number = 2
command_history.undo()  -- current_sequence_number = 1

-- Verify position ≤ max
assert(current_sequence_number <= last_sequence_number)
```

**Related Rules**: ENGINEERING.md §1.14 (assert policy), §2.20 (regression tests first)

---

## INV-005: Clip Timebase Matches Owner
**Statement**: Clips on a timeline MUST have the same fps_numerator/denominator as their owning sequence. Rescaling happens at import/insert time.

**Evidence**:
- `src/lua/core/commands/insert_clip_to_timeline.lua` - Rescales master clip to sequence rate
- `src/lua/core/clip_mutator.lua:152-154` - Asserts owning sequence fps matches clip fps
- `src/lua/importers/fcp7_xml_importer.lua` - Rescales imported clips to sequence rate

**How to Verify**:
```lua
-- Sequence at 24 fps
local seq = database.get_sequence(sequence_id)
assert(seq.fps_numerator == 24 and seq.fps_denominator == 1)

-- Media at 30 fps
local media = database.get_media(media_id)
assert(media.fps_numerator == 30 and media.fps_denominator == 1)

-- Insert creates timeline clip at 24 fps (rescaled)
local cmd = Command.create("InsertClipToTimeline", project_id)
cmd:set_parameter("media_id", media_id)
cmd:set_parameter("sequence_id", sequence_id)
command_manager.execute(cmd)

local clip = database.get_clip(clip_id)
assert(clip.fps_numerator == 24 and clip.fps_denominator == 1)
```

**Related Rules**: ENGINEERING.md §1.1 (error handling), §2.13 (no fallbacks)

---

## INV-006: Gap Edge Materialization
**Statement**: Ripple operations materialize gap edges as first-class entities. Gaps include: explicit (user-selected), implied (between clips), and temporary (during batch shifts).

**Evidence**:
- `docs/RIPPLE-ALGORITHM-RULES.md:1-2` - "Clips and gaps behave the same way"
- `src/lua/core/ripple/batch/pipeline.lua:18` - `materialize_gap_edges(ctx)`
- `docs/gap-materialization.md` - Gap edge lifecycle documentation

**How to Verify**:
```lua
-- Timeline: [ClipA][gap][ClipB]
-- Select ClipA's right edge
local edges = {
  {clip_id = "clipA", edge_type = "out", track_id = "v1"}
}

-- Execute ripple
local cmd = Command.create("BatchRippleEdit", project_id)
cmd:set_parameter("edge_infos", edges)
cmd:set_parameter("delta_frames", 10)
command_manager.execute(cmd)

-- Verify gap edge was materialized
local ctx = ripple_context.from_command(cmd)
local gap_edges = ctx.materialized_gap_edges
assert(#gap_edges > 0, "Gap edges not materialized")

-- Verify ClipB shifted
local clipB_after = database.get_clip("clipB")
assert(clipB_after.timeline_start_frame == clipB_before.timeline_start_frame + 10)
```

**Related Rules**: docs/RIPPLE-ALGORITHM-RULES.md (rules 1-15), ENGINEERING.md §2.16 (no shortcuts)

---

## INV-007: Selection Snapshot Determinism
**Statement**: Command execution snapshots selection state BEFORE mutations. Undo restores the PRE-snapshot, redo restores the POST-snapshot. UUIDs for temp gaps are deterministic (hash-based).

**Evidence**:
- `src/lua/core/command_state.lua:58-84` - `capture_selection_snapshot()`
- `docs/event-sourcing-uuid-determinism.md` - UUID generation rules
- `src/lua/schema.sql:186-192` - Commands table stores `selected_*_pre` and `selected_*_post`

**How to Verify**:
```lua
-- Select clips before edit
command_state.set_selected_clips({"clip1", "clip2"})

-- Execute command (takes pre-snapshot)
local cmd = Command.create("DeleteClip", project_id)
cmd:set_parameter("clip_id", "clip1")
command_manager.execute(cmd)

-- Verify pre-snapshot stored
local stored = database.get_command(cmd.id)
assert(stored.selected_clip_ids_pre == '["clip1","clip2"]')

-- Undo restores pre-snapshot
command_history.undo()
local restored = command_state.get_selected_clips()
assert(#restored == 2 and restored[1] == "clip1")
```

**Related Rules**: ENGINEERING.md §2.29 (BatchCommand snapshots), docs/selection_snapshot_strategy.md

---

## INV-008: FFI Parameter Validation Only
**Statement**: FFI functions (`src/qt_bindings.cpp`) validate parameters but contain ZERO business logic. All logic lives in Lua.

**Evidence**:
- `src/qt_bindings.cpp` - Functions check argument count/types, then call Qt directly
- ENGINEERING.md §2.18 - "FFI functions contain parameter validation (not business logic)"

**How to Verify**:
```cpp
// Example from qt_bindings.cpp
static int lua_QPushButton_create(lua_State* L) {
    // Parameter validation
    int argc = lua_gettop(L);
    if (argc < 1) {
        return luaL_error(L, "QPushButton.create requires text argument");
    }
    
    const char* text = lua_tostring(L, 1);
    if (!text) {
        return luaL_error(L, "QPushButton.create: text must be string");
    }
    
    // Direct Qt call (no business logic)
    QPushButton* btn = new QPushButton(QString::fromUtf8(text));
    
    // Return handle
    lua_pushlightuserdata(L, btn);
    return 1;
}
```

**Negative Example** (forbidden):
```cpp
// WRONG: Business logic in FFI
static int lua_addClipToTimeline(lua_State* L) {
    // ... parameter validation ...
    
    // ❌ FORBIDDEN: Overlap detection, ripple logic, etc.
    if (clip_overlaps_existing(clip_id)) {
        shift_downstream_clips(delta);
    }
    
    return 1;
}
```

**Related Rules**: ENGINEERING.md §1.10 (Stay in Your Layer), §2.18 (FFI vs Business Logic)

---

## INV-009: Database as Authoritative State
**Statement**: SQLite database is the single source of truth. In-memory caches (e.g., `clip_state.clip_cache`) are invalidated after every mutation.

**Evidence**:
- `src/lua/ui/timeline/state/clip_state.lua:168-179` - `invalidate_cache()` called after mutations
- `src/lua/ui/timeline/state/timeline_core_state.lua:68-87` - `reload_clips()` queries DB
- ENGINEERING.md §1.14 - "DB is treated as internal state"

**How to Verify**:
```lua
-- Initial state
local clips1 = clip_state.get_all_clips()
assert(#clips1 == 3)

-- Mutate database
local cmd = Command.create("DeleteClip", project_id)
cmd:set_parameter("clip_id", clips1[1].id)
command_manager.execute(cmd)

-- Cache should be invalidated
local clips2 = clip_state.get_all_clips()
assert(#clips2 == 2, "Cache not invalidated after mutation")

-- Verify DB is source of truth
local clips_db = database.get_clips(sequence_id)
assert(#clips_db == 2, "DB inconsistent with cache")
```

**Related Rules**: ENGINEERING.md §1.14 (DB as internal state), docs/anti-stale-data-patterns.md

---

## INV-010: No Silent Fallbacks
**Statement**: Missing required data (project_id, sequence_id, fps, etc.) triggers immediate failure. NO default values, silent degradation, or recovery paths.

**Evidence**:
- ENGINEERING.md §2.13 - "MANDATORY No Fallbacks or Default Values"
- `src/lua/core/command_manager.lua:72-77` - `ensure_active_project_id()` errors if unset
- `src/lua/core/clip_mutator.lua` - Asserts on missing metadata (see INV-001 evidence)

**How to Verify**:
```lua
-- Positive test: Valid data
local cmd = Command.create("AddClip", project_id)
cmd:set_parameter("sequence_id", sequence_id)
cmd:set_parameter("track_id", track_id)
local ok, err = command_manager.execute(cmd)
assert(ok)

-- Negative test: Missing required param
local cmd2 = Command.create("AddClip", project_id)
-- Omit sequence_id
local ok2, err2 = pcall(function() command_manager.execute(cmd2) end)
assert(not ok2, "Should fail without sequence_id")
assert(err2:match("sequence_id"), "Error should mention missing parameter")

-- Negative test: Missing active project
active_project_id = nil
local ok3, err3 = pcall(function() Command.create("AddClip") end)
assert(not ok3, "Should fail without active project_id")
```

**Related Rules**: ENGINEERING.md §1.14 (fail-fast), §2.13 (no fallbacks), §3.5 (actionable errors)

---

## INV-011: Ripple Lead Edge Anchoring
**Statement**: During ripple trim, the dragged edge (lead edge) remains anchored in timeline position. The clip lengthens/shortens, and downstream material shifts accordingly.

**Evidence**:
- docs/RIPPLE-ALGORITHM-RULES.md:7 - "Only the length of the item changes, not its start position"
- `src/lua/core/ripple/batch/pipeline.lua:20` - `determine_lead_edge(ctx)`
- docs/ripple-trim-semantics.md - Premiere Pro compatibility

**How to Verify**:
```lua
-- Timeline: [ClipA 0-100][ClipB 100-200]
-- Select ClipA's out edge (timeline position 100)
local edges = {{clip_id = "clipA", edge_type = "out", track_id = "v1"}}

-- Ripple +10 frames (extend ClipA)
local cmd = Command.create("BatchRippleEdit", project_id)
cmd:set_parameter("edge_infos", edges)
cmd:set_parameter("delta_frames", 10)
command_manager.execute(cmd)

-- Verify ClipA start unchanged, duration increased
local clipA = database.get_clip("clipA")
assert(clipA.timeline_start_frame == 0, "Start position moved (WRONG)")
assert(clipA.duration_frames == 110, "Duration not updated")

-- Verify ClipB shifted downstream
local clipB = database.get_clip("clipB")
assert(clipB.timeline_start_frame == 110, "ClipB not shifted")

-- Verify edit point anchored at 110 (original 100 + delta 10)
local edit_point = clipA.timeline_start_frame + clipA.duration_frames
assert(edit_point == 110, "Edit point drifted")
```

**Related Rules**: docs/RIPPLE-ALGORITHM-RULES.md (rules 7-8), ENGINEERING.md §3.2 (principle of least amazement)

---

## INV-012: Batch Command Snapshot Required
**Statement**: BatchCommand instances MUST populate `sequence_id` and `__snapshot_sequence_ids` for undo/redo to function correctly. Without snapshots, timeline appears frozen until restart.

**Evidence**:
- ENGINEERING.md §2.29 - "Snapshot Every BatchCommand"
- `src/lua/core/commands/batch_command.lua` - Checks for `__snapshot_sequence_ids`
- Multiple test failures when snapshots omitted

**How to Verify**:
```lua
-- Correct usage
local batch = Command.create("BatchCommand", project_id)
batch:set_parameter("sequence_id", sequence_id)
batch:set_parameter("__snapshot_sequence_ids", {sequence_id})
-- Add child commands...
command_manager.execute(batch)

-- Undo/redo works
command_history.undo()
local state = timeline_state.get_clips()
-- State correctly restored

-- Incorrect usage (FORBIDDEN)
local batch2 = Command.create("BatchCommand", project_id)
-- Omit snapshots
command_manager.execute(batch2)
command_history.undo()
-- Timeline appears frozen, requires restart to see changes
```

**Related Rules**: ENGINEERING.md §2.29 (snapshot rule), docs/timeline-undo-collaboration.md

---

## INV-013: Track Heights Persist Per-Sequence
**Statement**: Every sequence stores track heights in `sequence_track_layouts.track_heights_json`. New sequences inherit from `project_settings.track_height_template`. Heights reload verbatim on init.

**Evidence**:
- ENGINEERING.md §2.30 - "Persist Track Heights Per Sequence"
- `src/lua/schema.sql:164-168` - `sequence_track_layouts` table
- Timeline state modules persist on resize

**How to Verify**:
```lua
-- Resize track header
timeline_state.set_track_height("v1", 80)

-- Verify persisted to DB
local stmt = db:prepare("SELECT track_heights_json FROM sequence_track_layouts WHERE sequence_id = ?")
stmt:bind(1, sequence_id)
stmt:exec()
stmt:next()
local json = stmt:value(0)
assert(json:match('"v1":80'), "Track height not persisted")

-- Reload timeline (simulate restart)
timeline_state.reset()
timeline_state.init(db, sequence_id, project_id)

-- Verify height restored
local height = timeline_state.get_track_height("v1")
assert(height == 80, "Track height not restored")
```

**Related Rules**: ENGINEERING.md §2.30 (persistence rule), §1.5 (universal state persistence)

---

## INV-014: Test Expectations Immutable
**Statement**: Once a regression test exists, its assertions are canonical. Modifying expected values requires explicit approval. Fixes go in implementation, not tests.

**Evidence**:
- ENGINEERING.md §2.31 - "Never Change Existing Test Expectations Without Approval"
- ENGINEERING.md §2.20 - "Regression Tests First"

**How to Verify**:
```lua
-- Existing test
function test_ripple_shift()
  -- ... setup ...
  command_manager.execute(cmd)
  
  local clip = database.get_clip("clip1")
  assert(clip.timeline_start_frame == 50, "Expected position")  -- CANONICAL
end

-- ❌ FORBIDDEN: Adjusting test to match buggy code
function test_ripple_shift()
  -- ... setup ...
  command_manager.execute(cmd)
  
  local clip = database.get_clip("clip1")
  assert(clip.timeline_start_frame == 49, "Expected position")  -- WRONG: Changed expectation
end

-- ✅ CORRECT: Fix implementation, test stays the same
-- (Fix ripple algorithm to compute correct position)
function test_ripple_shift()
  -- ... setup ...
  command_manager.execute(cmd)
  
  local clip = database.get_clip("clip1")
  assert(clip.timeline_start_frame == 50, "Expected position")  -- UNCHANGED
end
```

**Related Rules**: ENGINEERING.md §2.31 (test immutability), §2.20 (regression tests first)

---

## INV-015: Foreign Key Cascade Integrity
**Statement**: SQLite foreign keys are ENABLED (`PRAGMA foreign_keys = ON`). Deleting a project cascades to sequences, clips, commands. Deleting a sequence cascades to tracks, clips.

**Evidence**:
- `src/lua/schema.sql:5` - `PRAGMA foreign_keys = ON`
- `src/lua/schema.sql:33` - `project_id ... ON DELETE CASCADE`
- `src/lua/schema.sql:60` - `project_id ... ON DELETE CASCADE`
- `src/lua/schema.sql:99` - `sequence_id ... ON DELETE CASCADE`

**How to Verify**:
```sql
-- Create hierarchy
INSERT INTO projects VALUES ('p1', 'Test Project', ...);
INSERT INTO sequences VALUES ('s1', 'p1', 'Sequence 1', ...);
INSERT INTO tracks VALUES ('t1', 's1', 'V1', 'VIDEO', ...);
INSERT INTO clips VALUES ('c1', 'p1', 't1', ...);

-- Delete project
DELETE FROM projects WHERE id = 'p1';

-- Verify cascade
SELECT COUNT(*) FROM sequences WHERE project_id = 'p1';  -- Result: 0
SELECT COUNT(*) FROM tracks WHERE sequence_id = 's1';    -- Result: 0
SELECT COUNT(*) FROM clips WHERE id = 'c1';              -- Result: 0
```

**Related Rules**: ENGINEERING.md §1.12 (external input validation), §1.14 (DB as internal state)

---

## Verification Checklist

Run this before major releases:

```bash
# 1. Run full test suite
cd tests
for test in test_*.lua; do
    lua $test || echo "FAIL: $test"
done

# 2. Verify schema integrity
sqlite3 ~/Documents/JVE\ Projects/Untitled\ Project.jvp "PRAGMA foreign_key_check;"
# Should return empty

# 3. Check for floating-point time usage
grep -r "to_seconds\|from_seconds" src/lua/core/ --exclude="rational.lua"
# Should only appear in rational.lua (UI helper)

# 4. Verify FFI layer purity
grep -C5 "lua_pushlightuserdata\|lua_touserdata" src/qt_bindings.cpp | grep -i "if\|for\|while"
# Should be minimal control flow (only validation)

# 5. Check assert coverage
grep -r "assert(" src/lua/core/*.lua | wc -l
# Should be > 100 (fail-fast policy)

# 6. Verify test expectations unchanged
git diff tests/*.lua | grep "assert.*=="
# Should require Joe's approval for any changes
```

---

## Invariant Violation Examples

### Example 1: Floating-Point Time
```lua
-- ❌ WRONG
local time = 100.5  -- frames as float
db:exec("UPDATE clips SET timeline_start_frame = " .. time)

-- ✅ CORRECT
local time = Rational.new(100, 24, 1)
db:exec("UPDATE clips SET timeline_start_frame = " .. time.frames)
```

### Example 2: Silent Fallback
```lua
-- ❌ WRONG
local sequence_id = cmd:get_parameter("sequence_id") or "default_sequence"

-- ✅ CORRECT
local sequence_id = cmd:get_parameter("sequence_id")
assert(sequence_id, "sequence_id is required")
```

### Example 3: Business Logic in FFI
```lua
-- ❌ WRONG (C++)
static int lua_addClip(lua_State* L) {
    // ... validation ...
    if (timeline_has_overlap(clip)) {
        shift_downstream_clips();  // Business logic!
    }
}

-- ✅ CORRECT (Lua)
function add_clip_command:execute()
    if timeline_has_overlap(self.clip_id) then
        shift_downstream_clips()
    end
end
```

---

## Conclusion

These invariants form the immutable foundation of JVE. Any deviation is a bug, not a feature request. When in doubt, fail loudly with an actionable error message (ENGINEERING.md §3.5, §1.14).
