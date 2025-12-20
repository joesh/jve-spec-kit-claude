# 07-RISK-REGISTER

## Purpose
Catalog ranked, concrete failure modes with impact on correctness, undo/state integrity, and performance. Every risk cites files, symbols, or flows from 01-06.

---

## RISK-001: Undo Stack Corruption on Transaction Failure
**Severity**: CRITICAL | **Likelihood**: MEDIUM | **Priority**: P0

**Failure Mode**: Command execution increments sequence number but fails before persist. Undo stack position points to non-existent command.

**Technical Detail**:
- `command_manager.lua:548` increments sequence via `history.increment_sequence_number()`
- `command_manager.lua:566-578` executes implementation (may fail)
- `command_manager.lua:612-623` persists command to DB
- **Gap**: No rollback between line 578 (failure) and line 612 (persist)
- If execution fails, sequence incremented but command not saved

**Concrete Symptom**:
```
User action: Execute command
State: sequence_number = 5 → 6 (line 548)
Result: execution_success = false (line 572)
Issue: commands table still has MAX(sequence_number) = 5
Next undo: Attempts to load command #6 → "command not found" → crash
```

**Invariants Violated**:
- INV-004 (Command Sequencing): sequence number gap created
- INV-012 (Command Persistence): sequence number assigned but not persisted

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Command Execution Flow, step 8 (increment sequence)
- 04-BEHAVIORAL-FLOWS.md §Undo Flow, line 1112 (load command by sequence)

**Related Debt**:
- 05-STRUCTURAL-DEBT.md §Transaction Management Helper (lines 590-617): missing unified rollback handler

**Test Gap**: GAP-015 (Transaction Rollback Recovery)

**Mitigation**: Wrap lines 548-623 in explicit transaction with rollback on failure:
```lua
local tx_ok = begin_transaction()
local seq_ok = history.increment_sequence_number()
if not seq_ok then rollback(); return false end

local exec_ok = execute_command_implementation()
if not exec_ok then rollback(); history.decrement_sequence_number(); return false end

command:save(db)
commit_transaction()
```

**Detection**: Assert after undo load: `assert(loaded_command ~= nil, "sequence gap detected")`

---

## RISK-002: Cascade Delete Orphans Command History
**Severity**: CRITICAL | **Likelihood**: LOW | **Priority**: P0

**Failure Mode**: Delete project/sequence triggers CASCADE DELETE on commands table. In-memory undo stack in `command_history.lua` points to deleted rows.

**Technical Detail**:
- `schema.sql:169-178` defines commands table with `project_id` foreign key
- `schema.sql:33` projects table: `ON DELETE CASCADE`
- `command_history.lua:53-59` loads `MAX(sequence_number)` on init, caches in memory
- Delete project → SQLite cascades to commands → undo stack still has sequence numbers 1-N
- Next redo: `command_manager.lua:1032` loads command → returns nil → crash

**Concrete Symptom**:
```
State: Project "Alpha" has commands 1-100
Action: Delete project "Alpha"
Result: All rows deleted from commands table
Issue: command_history.last_sequence_number = 100 (stale)
Next redo: execute_redo_command(50) → database.load_command(50) → nil → crash at line 1038
```

**Invariants Violated**:
- INV-012 (Command Persistence): commands deleted outside undo system
- INV-004 (Command Sequencing): in-memory sequence counter desynchronized

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Redo Flow: loads command at line 1032, assumes exists
- 02-ARCHITECTURE-MAP.md §Data Flow: command_history maintains in-memory stack

**Test Gap**: GAP-002 (Foreign Key Cascade Deletes)

**Mitigation Options**:
1. **Disable cascades**: Remove `ON DELETE CASCADE`, manually delete commands first
2. **Invalidate cache**: Hook into delete_project command, call `command_history.reset()`
3. **Soft delete**: Mark projects as deleted, prevent cascade until undo stack cleared

**Detection**: On redo, assert command exists:
```lua
local cmd = database.load_command(sequence_number)
assert(cmd ~= nil, "cascade delete orphaned undo stack")
```

---

## RISK-003: Video Overlap Epsilon Allows Sub-Frame Collision
**Severity**: HIGH | **Likelihood**: MEDIUM | **Priority**: P1

**Failure Mode**: Trigger's floating-point epsilon (0.000001s) permits sub-frame overlaps when rescaling between timebases.

**Technical Detail**:
- `schema.sql:267-268` trigger comparison uses `CAST(... AS REAL)` with `- 0.000001` epsilon
- Epsilon = 0.000001s = 1 microsecond ≈ 0.024 frames @ 24fps
- Rescaling 23.976fps → 24fps introduces rounding: `rational.lua:85` uses `math.floor(... + 0.5)`
- Two clips rescaled independently could land within epsilon, passing trigger but overlapping by 1 frame

**Concrete Symptom**:
```
Clip A: 23.976fps, ends at frame 100 → rescale to 24fps → 100.1 frames → floor to 100
Clip B: 23.976fps, starts at frame 100 → rescale to 24fps → 99.9 frames → floor to 100
Both clips now at timeline frame 100 (overlap)
Trigger: (100 * 1/24) < (100 * 1/24 + ...) - 0.000001 → 4.1667 < 4.1667 - 0.000001 → TRUE (no overlap detected)
```

**Invariants Violated**:
- INV-003 (Video Track No-Overlap): epsilon undermines guarantee
- INV-002 (No Floating-Point Time): trigger uses floats despite rational timebase

**Related Flows**:
- 02-ARCHITECTURE-MAP.md §Rational Timebase: rescaling uses floor + 0.5 rounding
- 03-CORE-INVARIANTS.md INV-003: trigger is enforcement mechanism

**Related Debt**:
- None directly, but trigger design conflicts with rational timebase philosophy

**Test Gap**: GAP-003 (Video Overlap Trigger Edge Cases)

**Mitigation**: Rewrite trigger to use integer-only comparison:
```sql
-- Convert to common denominator (LCM of fps_denominators), compare in integer space
WHERE (NEW.timeline_start_frame * NEW.fps_denominator * c.fps_numerator) <
      ((c.timeline_start_frame + c.duration_frames) * c.fps_denominator * NEW.fps_numerator)
  AND ((NEW.timeline_start_frame + NEW.duration_frames) * NEW.fps_denominator * c.fps_numerator) >
      (c.timeline_start_frame * c.fps_denominator * NEW.fps_numerator)
```

**Detection**: Post-insert validation:
```lua
local clips = database.load_clips(sequence_id)
for i = 1, #clips - 1 do
  local gap = clips[i+1].timeline_start_frame - (clips[i].timeline_start_frame + clips[i].duration_frames)
  assert(gap >= 0, "sub-frame overlap detected")
end
```

---

## RISK-004: Rescaling Chain Accumulates Rounding Errors
**Severity**: HIGH | **Likelihood**: HIGH | **Priority**: P1

**Failure Mode**: Multiple rescale operations compound rounding errors, causing timeline drift.

**Technical Detail**:
- `rational.lua:80-89` rescales via: `math.floor(frames * new_num * fps_den / (fps_num * new_den) + 0.5)`
- Each rescale rounds to nearest integer
- Ripple operations rescale edge deltas: clip timebase → sequence timebase → shift delta → back to clip timebase
- 10-clip ripple with 3 rescales each = 30 rounding operations

**Concrete Symptom**:
```
Original: 100 frames @ 23.976fps (24000/1001)
Rescale 1: → 30fps: 100 * 30 * 1001 / (24000 * 1) + 0.5 = 125.125 → 125 frames (-0.125)
Rescale 2: → 24fps: 125 * 24 * 1 / (30 * 1) + 0.5 = 100.0 → 100 frames (lucky)
Rescale 3: → 23.976fps: 100 * 24000 * 1 / (24 * 1001) + 0.5 = 100.04 → 100 frames (-0.04)

After 10 clips: cumulative error = -1.25 frames → visible as 52ms drift @ 24fps
```

**Invariants Violated**:
- INV-001 (Timebase Integrity): cumulative precision loss violates frame accuracy
- INV-005 (Clip Timebase Matches Owner): rescaled clips drift from true duration

**Related Flows**:
- 02-ARCHITECTURE-MAP.md §Rational Timebase: rescaling pattern used throughout
- 04-BEHAVIORAL-FLOWS.md §Ripple Edit Flow: rescales edge deltas at line 150 (assumed)

**Test Gap**: GAP-006 (Timebase Rescaling Precision Loss)

**Mitigation**: 
1. **Minimize rescales**: Keep edge deltas in sequence timebase, apply once at end
2. **Track error accumulation**: Maintain `error_frames` field, apply correction threshold
3. **Use higher precision**: Intermediate calculations in 64-bit integers before final round

**Detection**: Round-trip test:
```lua
local original = Rational.new(100, 24000, 1001)
local temp = original:rescale(30, 1):rescale(24, 1):rescale(24000, 1001)
assert(temp.frames == original.frames, "rescale chain lost precision")
```

---

## RISK-005: Temporary Gap Leak Pollutes Edge Queries
**Severity**: MEDIUM | **Likelihood**: MEDIUM | **Priority**: P1

**Failure Mode**: Batch ripple creates temp gaps but fails to remove them. Subsequent edge picker queries include stale gaps.

**Technical Detail**:
- `ripple/batch/prepare.lua` (assumed) creates temp gap IDs: `"temp_gap_{track_id}_{start}_{end}"`
- `batch_ripple_edit.lua` (2107 LOC) executes mutations, expected to clean temp gaps
- `timeline_core_state.lua:36-47` parses temp gap IDs but no centralized cleanup registry
- If ripple errors after gap creation (line ~1500 assumed) but before cleanup (line ~2000 assumed), gaps persist

**Concrete Symptom**:
```
Action: User ripples 5 clips, operation creates 3 temp gaps
State: temp_gap_track1_100_200, temp_gap_track1_300_400, temp_gap_track2_500_600
Error: Media limit exceeded at clip 4, ripple aborts (line ~1500)
Issue: Temp gaps still in gap_state registry
Next action: User clicks near frame 100 → edge_picker finds temp_gap_track1_100_200
Result: Drag operation targets invisible gap, creates bizarre timeline corruption
```

**Invariants Violated**:
- INV-006 (Gap Edge Materialization): temp gaps are implementation detail, should not leak
- INV-009 (Selection State Isolation): temp gaps pollute selection state

**Related Flows**:
- 02-ARCHITECTURE-MAP.md §Ripple Edit Flow: pipeline creates gaps, finalizes mutations
- 04-BEHAVIORAL-FLOWS.md §Batch Ripple Flow (assumed): multi-stage operation

**Related Debt**:
- 05-STRUCTURAL-DEBT.md §Temp Gap Identifier Module (lines 545-586): no centralized cleanup

**Test Gap**: GAP-007 (Ripple Edge Materialization Failures)

**Mitigation**: Wrap ripple in cleanup guard:
```lua
local temp_gaps = {}
local ok = xpcall(function()
  temp_gaps = materialize_gaps()
  process_shifts()
  finalize_mutations()
end, cleanup_handler)

-- Always runs
for _, gap_id in ipairs(temp_gaps) do
  gap_state.remove(gap_id)
end
```

**Detection**: Post-ripple assertion:
```lua
local gaps = gap_state.get_all()
for _, gap in ipairs(gaps) do
  assert(not gap.id:match("^temp_gap_"), "temp gap leaked")
end
```

---

## RISK-006: No-Op Detection Fails to Rollback Side Effects
**Severity**: MEDIUM | **Likelihood**: LOW | **Priority**: P2

**Failure Mode**: Command with `suppress_if_unchanged` executes side effects before state hash comparison, no-op rollback leaves side effects committed.

**Technical Detail**:
- `command_manager.lua:523-534` captures pre-hash
- `command_manager.lua:566-578` executes implementation (may write files, call external APIs)
- `command_manager.lua:587-610` compares hashes, calls `finish_as_noop()` if equal
- `finish_as_noop()` at line 247: rolls back DB transaction but cannot undo external side effects

**Concrete Symptom**:
```
Command: ImportMedia with suppress_if_unchanged
Pre-hash: calculates hash of media table
Execution: Copies file from /tmp to project folder (line ~150 of import_media.lua)
Post-hash: Same as pre-hash (media already imported)
Result: finish_as_noop() rolls back DB, but file copy still in project folder
Issue: Project now has orphaned file, consumes disk space, appears in file browser but not database
```

**Invariants Violated**:
- None directly, but violates ENGINEERING.md §1.1 (error handling excellence)

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Command Execution Flow, step 12 (no-op detection)

**Test Gap**: GAP-001 (No-Op Detection State Hash)

**Mitigation Options**:
1. **Prohibit side effects**: Enforce rule that commands with `suppress_if_unchanged` cannot perform external I/O
2. **Two-phase execution**: Dry-run first to check hash, then commit if needed
3. **Side-effect registry**: Track external operations, undo them on rollback

**Detection**: Static analysis:
```lua
-- At command registration
if command.suppress_if_unchanged then
  assert(command.has_side_effects == false, "no-op detection incompatible with side effects")
end
```

---

## RISK-007: Concurrent Command Execution Assigns Duplicate Sequences
**Severity**: CRITICAL | **Likelihood**: LOW | **Priority**: P1

**Failure Mode**: Two commands enter `execute()` simultaneously, both increment sequence number, create collision.

**Technical Detail**:
- `command_manager.lua:548` calls `history.increment_sequence_number()`
- `command_history.lua:101-108` reads `last_sequence_number`, increments, returns new value
- No mutex/lock around read-modify-write
- Qt event loop could dispatch two menu actions simultaneously (e.g., keyboard shortcut + mouse click)

**Concrete Symptom**:
```
Thread A: Enters execute(), reads last_sequence_number = 100
Thread B: Enters execute(), reads last_sequence_number = 100
Thread A: Increments to 101, sets command.sequence_number = 101
Thread B: Increments to 101, sets command.sequence_number = 101
Thread A: Persists command with sequence_number = 101
Thread B: Persists command with sequence_number = 101 → UNIQUE constraint violation → SQLITE_CONSTRAINT error
```

**Invariants Violated**:
- INV-004 (Command Sequencing): duplicate sequence numbers violate uniqueness

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Command Execution Flow, step 8 (increment sequence)

**Test Gap**: GAP-005 (Concurrent Command Execution)

**Mitigation**: 
1. **Single-threaded guarantee**: Assert Qt runs on main thread only, disable concurrent command dispatch
2. **Optimistic locking**: Catch UNIQUE constraint, retry with new sequence
3. **Mutex**: Protect increment with critical section:
```lua
local command_mutex = require("core.mutex")
function execute(command)
  command_mutex:lock()
  local sequence_number = history.increment_sequence_number()
  command_mutex:unlock()
  -- rest of execution
end
```

**Detection**: Constraint violation handler:
```lua
local ok, err = command:save(db)
if not ok and err:match("UNIQUE constraint failed: commands.sequence_number") then
  logger.error("Concurrent command execution detected")
  return retry_with_new_sequence()
end
```

---

## RISK-008: Playhead Not Restored After Undo
**Severity**: MEDIUM | **Likelihood**: HIGH | **Priority**: P1

**Failure Mode**: Undo restores timeline content but leaves playhead at post-edit position, causing misaligned subsequent operations.

**Technical Detail**:
- `command_manager.lua:558-559` captures playhead: `command.playhead_value`, `command.playhead_rate`
- `command_manager.lua:1112-1210` executes undo but never calls `timeline_state.set_playhead_position()`
- Playhead saved but not restored

**Concrete Symptom**:
```
Initial state: Playhead at frame 100
Action: 50-frame ripple right, playhead moves to frame 150 (follows edit)
Undo: Timeline content shifts back to frame 100 position
Issue: Playhead still at frame 150
Next insert: User presses 'I' for insert, clip inserts at frame 150 instead of expected 100
Result: Clip inserted 50 frames away from visible cursor position
```

**Invariants Violated**:
- INV-010 (Playhead Persistence): playhead should restore with timeline state

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Command Execution Flow, step 9 (capture pre-state)
- 04-BEHAVIORAL-FLOWS.md §Undo Flow: line 1112 (execute_undo)

**Test Gap**: GAP-009 (Playhead Position Snapshot Timing)

**Mitigation**: Add playhead restoration to undo:
```lua
-- command_manager.lua:1112
function execute_undo(...)
  local original_command = load_command(...)
  
  -- Execute undo logic
  local ok = undoer(original_command)
  
  -- Restore playhead
  if original_command.playhead_value and original_command.playhead_rate then
    timeline_state.set_playhead_position(original_command.playhead_value, original_command.playhead_rate)
  end
  
  return ok
end
```

**Detection**: Test pattern:
```lua
local pre_playhead = timeline_state.get_playhead_position()
command_manager.execute(ripple_command)
local post_playhead = timeline_state.get_playhead_position()
command_manager.undo()
local restored_playhead = timeline_state.get_playhead_position()
assert(restored_playhead == pre_playhead, "playhead not restored")
```

---

## RISK-009: FFI Crash on Invalid Parameters
**Severity**: HIGH | **Likelihood**: MEDIUM | **Priority**: P2

**Failure Mode**: Lua passes invalid parameter to Qt binding (negative width, nil pointer), crashes in C++ layer.

**Technical Detail**:
- `qt_bindings.cpp` 1300+ LOC exposes Qt APIs
- Limited parameter validation (02-ARCHITECTURE-MAP.md: "Parameter validation ONLY")
- Qt APIs have preconditions (e.g., QWidget::resize expects width > 0)
- Invalid parameter triggers Qt assertion → abort() → application crash

**Concrete Symptom**:
```
Lua: qt_constants.WIDGET.SET_SIZE(widget, -100, 200)
C++: QWidget::resize(-100, 200)
Qt: Q_ASSERT(width >= 0) → assertion failed → abort()
Result: Immediate application crash, no error message in Lua, no undo possible
```

**Invariants Violated**:
- ENGINEERING.md §1.10 (FFI Layer): validation should prevent invalid calls reaching Qt
- ENGINEERING.md §1.12 (External Input Validation): Lua assumes FFI validates

**Related Flows**:
- 02-ARCHITECTURE-MAP.md §FFI Layer: "Pure interface to Qt6"

**Test Gap**: GAP-010 (FFI Parameter Validation Bypass)

**Mitigation**: Add validation to every binding:
```cpp
// qt_bindings.cpp
static int qt_widget_set_size(lua_State* L) {
  QWidget* widget = lua_to_widget(L, 1);
  if (!widget) return luaL_error(L, "Invalid widget");
  
  int width = luaL_checkinteger(L, 2);
  int height = luaL_checkinteger(L, 3);
  
  if (width < 0) return luaL_error(L, "Width must be non-negative");
  if (height < 0) return luaL_error(L, "Height must be non-negative");
  
  widget->resize(width, height);
  return 0;
}
```

**Detection**: Fuzz testing:
```lua
for i = 1, 1000 do
  local width = math.random(-1000, 1000)
  local height = math.random(-1000, 1000)
  local ok, err = pcall(qt_constants.WIDGET.SET_SIZE, widget, width, height)
  if not ok and not err:match("must be non%-negative") then
    error("Unexpected error: " .. err)
  end
end
```

---

## RISK-010: Import Replay on Undo Tree Switch Stalls UI
**Severity**: MEDIUM | **Likelihood**: LOW | **Priority**: P2

**Failure Mode**: User branches undo tree after large import. Switching branches replays import command, re-parsing 10,000+ clips.

**Technical Detail**:
- `command_manager.lua:809-826` replays commands on undo tree switch
- Import commands (FCP7 XML, Resolve DRP) create thousands of timeline clips
- Unclear if imports skip replay (04-BEHAVIORAL-FLOWS.md mentions skip for non-recording)
- 10,000-clip XML parse takes ~30 seconds (single-threaded)

**Concrete Symptom**:
```
Action: Import 10,000-clip FCP7 XML (command #50)
Edit: Make timeline edits (commands #51-60)
Undo: Undo past import to command #49
Branch: Make new edit (command #61, creates branch)
Switch back: User switches to branch with command #60
Result: replay_from(50) re-executes import → 30-second UI freeze → appears hung
```

**Invariants Violated**:
- None directly, but violates ENGINEERING.md performance expectations

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Replay Flow: line 809 (replay_from)

**Test Gap**: GAP-011 (Import Undo Command Replay Skip)

**Mitigation Options**:
1. **Skip import replay**: Add imports to skip list:
```lua
if cmd.type == "ImportFCP7XML" or cmd.type == "ImportResolveProject" then
  -- Skip replay, assume imported content already in DB
  goto continue
end
```
2. **Snapshot imports**: Create clip snapshot after import, restore from snapshot instead of replay
3. **Async replay**: Background thread for replay with progress indicator

**Detection**: Performance monitoring:
```lua
local start_time = os.clock()
command_manager.replay_from(sequence_number)
local elapsed = os.clock() - start_time
if elapsed > 1.0 then
  logger.warn("Slow replay: " .. elapsed .. "s")
end
```

---

## RISK-011: Clip Link Desync Under Ripple
**Severity**: MEDIUM | **Likelihood**: MEDIUM | **Priority**: P2

**Failure Mode**: Ripple operation selects video clip edge but not linked audio edge. Ripple shifts video only, breaking A/V sync.

**Technical Detail**:
- `clip_links.lua` maintains linked clip pairs (assumed audio/video synchronization)
- `batch_ripple_edit.lua` processes edge selection
- If user selects only video clip edge, ripple shifts video clip
- Linked audio clip not in selection → stays at original position
- Clips now have different `timeline_start_frame` values

**Concrete Symptom**:
```
Initial: Video clip at frame 100, Audio clip at frame 100 (linked)
Action: User selects video out-point, performs 20-frame ripple trim
Result: Video clip now ends at frame 120, audio clip still at frame 100
Issue: 20-frame A/V desync, audio plays 20 frames early relative to video
Viewer: Lip sync error visible to user
```

**Invariants Violated**:
- INV-008 (Clip Links Integrity): linked clips should maintain relative timing

**Related Flows**:
- 02-ARCHITECTURE-MAP.md §Ripple Edit Flow: processes edge selection

**Test Gap**: GAP-012 (Clip Link Constraint Enforcement)

**Mitigation**: Expand selection to include linked clips:
```lua
-- batch_ripple_edit.lua
local function expand_selection_for_links(edge_selection)
  local expanded = {}
  for _, edge_info in ipairs(edge_selection) do
    table.insert(expanded, edge_info)
    
    local linked_clip_ids = clip_links.get_linked_clips(edge_info.clip_id)
    for _, linked_id in ipairs(linked_clip_ids) do
      local linked_edge = {
        clip_id = linked_id,
        edge_type = edge_info.edge_type,
        track_id = get_track_for_clip(linked_id)
      }
      table.insert(expanded, linked_edge)
    end
  end
  return expanded
end
```

**Detection**: Post-ripple validation:
```lua
local links = clip_links.get_all_links()
for _, link in ipairs(links) do
  local clip_a = database.get_clip(link.clip_a_id)
  local clip_b = database.get_clip(link.clip_b_id)
  local offset = clip_a.timeline_start_frame - clip_b.timeline_start_frame
  assert(offset == link.initial_offset, "linked clips desynchronized")
end
```

---

## RISK-012: Mutation Application Silently Falls Back to Full Reload
**Severity**: LOW | **Likelihood**: MEDIUM | **Priority**: P3

**Failure Mode**: Malformed `__timeline_mutations` parameter causes `apply_mutations()` to fail silently, triggers expensive full reload.

**Technical Detail**:
- `command_manager.lua:1171-1191` applies mutations during undo
- If `timeline_state.apply_mutations()` returns false, falls back to `reload_clips()` at line 1189
- No error logged, user unaware of performance degradation
- Incremental update (O(n) in changed clips) becomes full reload (O(n) in total clips)

**Concrete Symptom**:
```
Normal undo: 5 clips changed → apply_mutations updates 5 clip cache entries → 1ms
Corrupted mutation: bucket.updates = "invalid" → apply_mutations returns false → reload_clips loads 10,000 clips → 500ms
Result: Undo appears laggy, user notices "stuttering" on complex timelines
Issue: No indication that incremental path failed, silently degrades to slow path
```

**Invariants Violated**:
- None directly, but violates performance expectations from INV-011 (Undo Completeness)

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Undo Flow: mutation application at line 1171

**Related Debt**:
- 05-STRUCTURAL-DEBT.md §Timeline Mutation Application (lines 38-83): duplicated logic

**Test Gap**: GAP-004 (Undo Mutation Hydration Errors)

**Mitigation**: Log fallback and add telemetry:
```lua
if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
  logger.warn("Mutation application failed, falling back to full reload", {
    command_type = original_command.type,
    sequence_number = original_command.sequence_number
  })
  timeline_state.reload_clips(reload_sequence_id)
end
```

**Detection**: Performance test:
```lua
local start_time = os.clock()
command_manager.undo()
local elapsed = os.clock() - start_time
assert(elapsed < 0.1, "Undo took " .. elapsed .. "s, likely using full reload")
```

---

## RISK-013: Command Listener Sees Uncommitted Transaction State
**Severity**: MEDIUM | **Likelihood**: LOW | **Priority**: P2

**Failure Mode**: Listener callback executes after COMMIT but before WAL checkpoint. Concurrent reader sees pre-commit state.

**Technical Detail**:
- `command_manager.lua:645` commits transaction
- `command_manager.lua:651-658` notifies listeners
- `schema.sql:6` enables WAL mode: `PRAGMA journal_mode = WAL`
- WAL mode: writes go to separate log, checkpoint merges to main DB
- Listener queries DB → could hit main DB before checkpoint → sees old state

**Concrete Symptom**:
```
Thread A: Executes command, modifies clip at frame 100 → 150
Thread A: Commits transaction (writes to WAL)
Thread A: Notifies listener: {event = "executed"}
Thread B (listener): Queries database.get_clip(clip_id)
Thread B: Hits main DB (WAL not checkpointed yet)
Thread B: Sees clip at frame 100 (old value)
Thread B: Updates UI cache with stale data
Result: UI shows clip at frame 100, actual DB has frame 150 after next checkpoint
```

**Invariants Violated**:
- INV-012 (Command Persistence): listener assumes durable state, may not be checkpointed

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Command Execution Flow, step 16 (notify listeners)

**Test Gap**: GAP-008 (Command Listener Notification Order)

**Mitigation Options**:
1. **Explicit checkpoint**: Call `PRAGMA wal_checkpoint(PASSIVE)` before notify
2. **Delay notification**: Defer listener callbacks until next event loop iteration
3. **Connection reopen**: Force listener to reopen connection, seeing WAL changes

**Detection**: Listener validation:
```lua
function on_command_executed(event)
  local clip = database.get_clip(event.command.parameters.clip_id)
  local expected = event.command.parameters.new_timeline_start
  assert(clip.timeline_start_frame == expected, "listener sees uncommitted state")
end
```

---

## RISK-014: Snapshot at Sequence Boundary Excludes Clips
**Severity**: LOW | **Likelihood**: LOW | **Priority**: P3

**Failure Mode**: Snapshot created at frame 0 or beyond sequence duration doesn't capture clips outside "active region", causing incomplete undo.

**Technical Detail**:
- `snapshot_manager.lua` (assumed) creates snapshots for undo optimization
- Snapshots likely capture "active region" around edit point for efficiency
- Clips at frame 0 or beyond sequence end may be outside snapshot range
- Undo restoration loads snapshot → missing clips → timeline incomplete

**Concrete Symptom**:
```
Timeline: Clips at frames 0-100, 1000-1100 (gap in middle)
Edit: Ripple at frame 500, creates snapshot of frames 400-600
Undo: Restores from snapshot
Issue: Clips at 0-100 and 1000-1100 not in snapshot → missing from timeline
Result: Timeline shows only frames 400-600, rest of content vanished
```

**Invariants Violated**:
- INV-013 (Snapshot Consistency): snapshot should capture all affected clips

**Related Flows**:
- 04-BEHAVIORAL-FLOWS.md §Command Execution Flow, step 14 (snapshotting)

**Test Gap**: GAP-014 (Snapshot Boundary Conditions)

**Mitigation**: Expand snapshot range to full sequence:
```lua
function create_snapshot(db, sequence_id, sequence_number)
  local sequence = database.get_sequence(sequence_id)
  local all_clips = database.load_clips(sequence_id)  -- No range filter
  
  local snapshot_data = serialize_clips(all_clips)
  db:exec("INSERT INTO clip_snapshots VALUES (?, ?, ?)", 
    sequence_id, sequence_number, snapshot_data)
end
```

**Detection**: Post-undo clip count validation:
```lua
local pre_clips = database.load_clips(sequence_id)
command_manager.execute(command)
command_manager.undo()
local post_clips = database.load_clips(sequence_id)
assert(#post_clips == #pre_clips, "snapshot lost clips")
```

---

## Summary Statistics

### Risk Distribution by Severity
- **CRITICAL**: 3 risks (001, 002, 007)
- **HIGH**: 3 risks (003, 004, 009)
- **MEDIUM**: 6 risks (005, 006, 008, 010, 011, 013)
- **LOW**: 2 risks (012, 014)

### Risk Distribution by System Component
| Component | Risks | Highest Severity |
|-----------|-------|------------------|
| Command Manager | 4 | CRITICAL (001, 002, 007) |
| Timebase System | 2 | HIGH (003, 004) |
| Ripple Algorithm | 2 | MEDIUM (005, 011) |
| State Management | 3 | MEDIUM (006, 008, 013) |
| FFI Layer | 1 | HIGH (009) |
| Import System | 1 | MEDIUM (010) |
| Snapshot System | 1 | LOW (014) |
| Undo System | 1 | LOW (012) |

### P0 Priorities (Must Fix Before v1.0)
1. **RISK-001** - Transaction rollback corruption
2. **RISK-002** - Cascade delete orphans undo stack
3. **RISK-007** - Concurrent sequence assignment

### P1 Priorities (Should Fix Before Beta)
1. **RISK-003** - Video overlap epsilon
2. **RISK-004** - Rescaling precision loss
3. **RISK-005** - Temp gap leak
4. **RISK-008** - Playhead not restored

### Highest Exposure Risks (Severity × Likelihood)
1. **RISK-004** - Rescaling chain errors (HIGH × HIGH = 9)
2. **RISK-008** - Playhead restoration (MEDIUM × HIGH = 6)
3. **RISK-009** - FFI crashes (HIGH × MEDIUM = 6)
4. **RISK-003** - Overlap epsilon (HIGH × MEDIUM = 6)
5. **RISK-005** - Temp gap leak (MEDIUM × MEDIUM = 4)

### Mitigation Complexity
- **Low** (1-10 LOC): 006, 008, 012, 013
- **Medium** (10-50 LOC): 004, 005, 011, 014
- **High** (50+ LOC or architectural): 001, 002, 003, 007, 009, 010
