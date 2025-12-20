# 06-TEST-GAPS

## Purpose
Catalog missing or weak test coverage by analyzing test suite against code paths, invariants, and behavioral flows documented in 01-05. Focus on correctness-critical gaps, not exhaustive coverage.

---

## GAP-001: No-Op Detection (State Hash)
**Missing Coverage**: Commands with `suppress_if_unchanged` flag (`command_manager.lua:587-610`)

**Evidence**:
- Zero tests found for `state_hash` or `suppress_if_unchanged` keywords
- `state_mgr.calculate_state_hash()` called at lines 523-534, 596-601
- `finish_as_noop()` path (line 247) untested: rollback + sequence decrement logic

**Code Path**:
```
command_manager.execute()
  → compute pre_hash (line 528)
  → execute implementation
  → compute post_hash (line 596)
  → if pre_hash == post_hash: finish_as_noop() (line 602)
    → db:exec("ROLLBACK") (line 249)
    → history.decrement_sequence_number() (line 252)
```

**Invariant Risk**: INV-004 (Command Sequencing) - sequence number decrement could violate monotonicity if transaction rollback fails mid-flight.

**Why Critical**: No-op path bypasses normal undo stack management. Decrement logic could corrupt sequence numbers if rollback incomplete.

**Existing Coverage**: None identified

---

## GAP-002: Foreign Key Cascade Deletes
**Missing Coverage**: CASCADE DELETE triggers in schema (`schema.sql:5`)

**Evidence**:
- `PRAGMA foreign_keys = ON` enables cascades
- Zero tests found matching `foreign_key`, `cascade`, or `referential` patterns
- Cascade paths:
  - Delete project → deletes media, sequences, commands
  - Delete sequence → deletes tracks, clips, commands
  - Delete track → deletes clips

**Code Path**:
```sql
-- schema.sql:32-33
project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE

-- schema.sql:63-64  
project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE

-- schema.sql:121-122
sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE
```

**Invariant Risk**: INV-012 (Command Persistence) - cascade delete of `commands` table rows bypasses undo system. Deleted commands cannot be replayed for redo.

**Why Critical**: Orphaned command references in `command_history` module's in-memory stack (lines 53-59) could point to deleted rows. Redo would fail with "command not found" error.

**Existing Coverage**: 
- Partial: `test_delete_sequence.lua` exists but doesn't verify cascade cleanup
- Missing: Project-level cascades, command table cleanup verification

---

## GAP-003: Video Overlap Trigger Edge Cases
**Missing Coverage**: Trigger boundary conditions (`schema.sql:254-303`)

**Evidence**:
- Trigger uses floating-point comparison: `CAST(... AS REAL)` with `0.000001` epsilon
- Tests found: 6 files reference `VIDEO_OVERLAP` error
- Missing cases:
  - Clips adjacent within epsilon tolerance (e.g., gap of 0.0000005 seconds)
  - Updates that change both `timeline_start_frame` and `duration_frames` simultaneously
  - Rescaling operations where floating-point conversion introduces rounding

**Code Path**:
```sql
-- schema.sql:267-268
(CAST(NEW.timeline_start_frame AS REAL) * NEW.fps_denominator / NEW.fps_numerator) <
(CAST(c.timeline_start_frame AS REAL) * c.fps_denominator / c.fps_numerator + ...) - 0.000001
```

**Invariant Risk**: INV-003 (Video Track No-Overlap) + INV-002 (No Floating-Point Time) - rational timebase undermined by trigger's float conversion. Epsilon of 0.000001s ≈ 0.024 frames @ 24fps could allow sub-frame overlaps.

**Why Critical**: Trigger is last line of defense. If epsilon allows overlap, downstream ripple operations assume no-overlap invariant and produce corrupt timelines.

**Existing Coverage**:
- Partial: `test_batch_ripple_upstream_overlap.lua`, `test_nudge_block_resolves_overlaps.lua`
- Missing: Epsilon boundary tests, simultaneous field updates, cross-timebase scenarios

---

## GAP-004: Undo Mutation Hydration Errors
**Missing Coverage**: Malformed `__timeline_mutations` parameter recovery

**Evidence**:
- `command_manager.lua:1171-1191` applies mutations during undo
- No validation that mutations are well-formed before `timeline_state.apply_mutations()` call
- If mutation bucket missing `sequence_id`, fallback to `reload_sequence_id` (line 1176)
- Zero tests for malformed mutations: `{inserts = nil}`, `{updates = "not_a_table"}`, missing sequence_id

**Code Path**:
```lua
-- command_manager.lua:1171-1191
local mutations = original_command:get_parameter("__timeline_mutations")
if mutations and timeline_state.apply_mutations then
  if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
    applied_mutations = timeline_state.apply_mutations(mutations.sequence_id or reload_sequence_id, mutations)
  else
    for _, bucket in pairs(mutations) do  -- No validation on bucket structure
      if timeline_state.apply_mutations(bucket.sequence_id or reload_sequence_id, bucket) then
        applied_mutations = true
      end
    end
  end
end
```

**Invariant Risk**: INV-011 (Undo Completeness) - corrupted mutations cause undo to fail silently. `applied_mutations = false` triggers full reload (line 1189) but doesn't report error.

**Why Critical**: Corrupted command persisted to DB (e.g., via schema migration bug or manual edit) causes undo stack to degrade into full-reload mode, defeating incremental update performance.

**Existing Coverage**:
- Partial: `test_command_manager_missing_undoer.lua` tests missing undo function
- Missing: Mutation structure validation, bucket iteration failure modes

---

## GAP-005: Concurrent Command Execution
**Missing Coverage**: Multi-threaded access to command_manager state

**Evidence**:
- Only 1 test found: `test_batch_ripple_concurrent.lua`
- `command_manager.lua` uses module-level state: `last_error_message` (line 62), `active_command_metadata` (line 60)
- No mutex/lock protection around transaction begin/commit (lines 513-645)
- Qt event loop could trigger commands from multiple widgets simultaneously

**Code Path**:
```lua
-- command_manager.lua:62-63
local last_error_message = ""
local active_command_metadata = nil

-- command_manager.lua:513-520 (no lock acquisition)
local begin_tx = db:prepare("BEGIN TRANSACTION")
begin_tx:exec()  -- Race condition if two threads enter simultaneously
```

**Invariant Risk**: INV-004 (Command Sequencing) - race on `history.increment_sequence_number()` (line 548) could assign duplicate sequence numbers. INV-012 (Command Persistence) - interleaved transaction commits corrupt undo tree.

**Why Critical**: SQLite WAL mode allows concurrent reads but SERIALIZED transactions. Two commands starting transactions before either commits leads to `SQLITE_BUSY` error. No retry logic exists.

**Existing Coverage**:
- Minimal: `test_batch_ripple_concurrent.lua` (single test)
- Missing: Transaction conflict scenarios, state variable races, error recovery

---

## GAP-006: Timebase Rescaling Precision Loss
**Missing Coverage**: Rounding errors in `rational.lua:rescale()`

**Evidence**:
- `rational.lua:80-89` uses `math.floor(... + 0.5)` for rounding
- Tests found: 11 files with `rational` or `timebase` keywords
- Missing cases:
  - Rescale chains: 24fps → 30fps → 23.976fps (cumulative rounding)
  - Large frame counts: `frames > 2^53` (Lua number precision limit)
  - Denominator > numerator: 1000/1001 vs 1001/1000

**Code Path**:
```lua
-- rational.lua:80-89
function Rational:rescale(new_num, new_den)
  local new_frames = math.floor(
    self.frames * new_num * self.fps_denominator /
    (self.fps_numerator * new_den) + 0.5
  )
  return Rational.new(new_frames, new_num, new_den)
end
```

**Invariant Risk**: INV-001 (Timebase Integrity) + INV-002 (No Floating-Point Time) - intermediate float multiplication could overflow or lose precision. INV-005 (Clip Timebase Matches Owner) - rescaling at insert produces wrong frame count.

**Why Critical**: Ripple operations rescale edge deltas across timebases. Cumulative rounding errors in multi-clip shifts lead to timeline drift (clips no longer frame-accurate).

**Existing Coverage**:
- Partial: `test_rational.lua`, `test_full_timebase_pipeline.lua`
- Missing: Rescale chain tests, large frame count tests, precision loss bounds verification

---

## GAP-007: Ripple Edge Materialization Failures
**Missing Coverage**: Temporary gap edge cleanup after batch ripple

**Evidence**:
- `ripple/batch/pipeline.lua` materializes temporary gaps for multi-clip operations
- `timeline_core_state.lua:36-47` parses temp gap identifiers: `"temp_gap_{track_id}_{start}_{end}"`
- Zero tests verify temp gaps removed after ripple completes
- `gap_state.lua` maintains temp gap registry but no cleanup verification

**Code Path**:
```lua
-- ripple/batch/prepare.lua (creates temp gaps)
local temp_id = string.format("temp_gap_%s_%d_%d", track_id, start_frames, end_frames)

-- batch_ripple_edit.lua (execution)
execute() → materialize gaps → process shifts → finalize mutations

-- Missing: explicit temp gap cleanup before command returns
```

**Invariant Risk**: INV-006 (Gap Edge Materialization) - leaked temp gaps appear in subsequent edge queries. INV-009 (Selection State Isolation) - temp gaps pollute selection state if not cleaned.

**Why Critical**: Temp gaps with IDs matching pattern persist in `gap_state` after ripple. Next edge picker operation includes stale gaps, causing incorrect drag target selection. User drags clip to "invisible" gap position.

**Existing Coverage**:
- Partial: `test_batch_ripple_gap_undo_no_temp_gap.lua` tests undo cleanup
- Missing: Execute path cleanup, multi-sequence ripple cleanup, error path cleanup

---

## GAP-008: Command Listener Notification Order
**Missing Coverage**: Notification timing relative to transaction commit

**Evidence**:
- `command_manager.lua:651-658` notifies listeners AFTER commit (line 645)
- `command_manager.lua:1078-1083` notifies AFTER redo mutations applied
- No tests verify listener sees committed state vs in-flight transaction state
- Listeners could query DB before commit finishes in WAL mode

**Code Path**:
```
command_manager.execute()
  → db:exec("COMMIT") (line 645)
  → notify_command_event({event = "executed"}) (line 654)
    → listener callback runs
      → callback queries database
        → WAL mode: could see pre-commit state from parallel reader
```

**Invariant Risk**: INV-012 (Command Persistence) - listener sees command not yet durable. Crash between commit and WAL checkpoint loses command but listener already processed it.

**Why Critical**: Timeline UI listeners refresh clip cache on "executed" event. If commit not durable, crash loses command but UI shows updated state. Undo stack position now mismatched with actual DB state.

**Existing Coverage**: None identified

---

## GAP-009: Playhead Position Snapshot Timing
**Missing Coverage**: Playhead capture in `command_manager.lua:556-563` before execution

**Evidence**:
- Pre-execution: captures playhead at line 558-559
- Post-execution: no playhead re-capture for undo restoration
- Undo path: `execute_undo()` at line 1112 does not restore playhead from `command.playhead_value`
- Zero tests verify playhead position after undo/redo cycle

**Code Path**:
```lua
-- command_manager.lua:556-563
command.playhead_value = timeline_state.get_playhead_position()
command.playhead_rate = timeline_state.get_sequence_frame_rate()

-- command_manager.lua:1112-1210 (execute_undo)
-- No call to timeline_state.set_playhead_position(command.playhead_value)
```

**Invariant Risk**: INV-010 (Playhead Persistence) - playhead saved but never restored. After undo, playhead at wrong position relative to timeline content.

**Why Critical**: User makes 10-frame ripple, moves playhead to new position, undos ripple. Playhead now points to wrong frame offset. Subsequent insert/overwrite operations target incorrect timeline position.

**Existing Coverage**: None identified for playhead restoration

---

## GAP-010: FFI Parameter Validation Bypass
**Missing Coverage**: Lua → C++ boundary type checking in `qt_bindings.cpp`

**Evidence**:
- `qt_bindings.cpp` 1300+ LOC exposes Qt to Lua
- Only 1 C++ test: `test_qt_bindings.cpp` (113 lines)
- Tests verify happy path function availability (lines 21-43, 45-67)
- Missing: Wrong parameter types (string instead of number), nil parameters, out-of-range values

**Code Path**:
```cpp
// qt_bindings.cpp (example validation)
if (!lua_isnumber(L, 2)) {
  return luaL_error(L, "Expected number for parameter 2");
}
int value = lua_tointeger(L, 2);
```

**Invariant Risk**: ENGINEERING.md §1.10 (FFI Layer Never Contains Business Logic) - missing validation forces C++ layer to make policy decisions. §1.12 (External Input Validation) - Lua layer assumes FFI validates parameters.

**Why Critical**: Invalid parameter (e.g., negative widget width) passed to Qt crashes application via assertion. No Lua-level error handling possible since crash occurs in C++.

**Existing Coverage**:
- Minimal: `test_qt_bindings.cpp` tests 2 functions with valid inputs
- Missing: Negative tests (wrong types, nil, out-of-range), all 1300 LOC of bindings

---

## GAP-011: Import Undo Command Replay Skip
**Missing Coverage**: Verification that import commands don't replay on undo tree rebuild

**Evidence**:
- `test_import_undo_skips_replay.lua` tests single import
- No tests verify behavior after branching undo tree with multiple imports
- `command_manager.lua:809-826` (replay_from) has special case for import commands
- Unclear if replay skip applies to nested imports (DRP contains FCP7 XML references)

**Code Path**:
```lua
-- command_manager.lua:809-826
function M.replay_from(sequence_number, dry_run)
  local commands = load_commands_from(sequence_number)
  for _, cmd in ipairs(commands) do
    if cmd.type == "ImportFCP7XML" or cmd.type == "ImportResolveProject" then
      -- Skip or execute?
    end
    execute_redo_command(cmd, dry_run)
  end
end
```

**Invariant Risk**: INV-012 (Command Persistence) - import creates thousands of commands. Replaying import on undo tree switch re-executes expensive parser. INV-004 (Command Sequencing) - skipped imports create sequence number gaps.

**Why Critical**: User imports 10,000-clip FCP7 XML, makes edits, undos past import, branches with new edit. Replay-from now re-runs XML parser, stalling UI for 30+ seconds.

**Existing Coverage**:
- Partial: `test_import_undo_skips_replay.lua`, `test_import_undo_removes_sequence.lua`
- Missing: Nested import replay, branching with imports, multiple simultaneous imports

---

## GAP-012: Clip Link Constraint Enforcement
**Missing Coverage**: Clip linking operations under ripple edits

**Evidence**:
- `clip_links.lua` manages linked audio/video clip pairs
- Only 2 tests in `ad_hoc/`: `test_enhanced_relinking.lua`, `test_media_relinking.lua`
- Ad-hoc tests not run in main test suite (separate directory)
- Ripple operations could unlink clips if only one clip in pair selected

**Code Path**:
```lua
-- commands/link_clips.lua creates link
-- commands/batch_ripple_edit.lua processes edges
  → if linked clip not in edge selection
    → ripple shifts one clip, other clip stays
    → clips now at different timeline positions (unlinked)
```

**Invariant Risk**: INV-008 (Clip Links Integrity) (assumed from `clip_links.lua` existence) - ripple breaks link without error. User expects linked A/V to stay synchronized.

**Why Critical**: User selects video clip's out-point, performs ripple trim. Audio remains at original out-point. Timeline now has mismatched A/V, visible as sync drift in viewer.

**Existing Coverage**:
- None in main test suite (`tests/`)
- Ad-hoc only (not automated)

---

## GAP-013: Error System Localization Path
**Missing Coverage**: Error messages through `error_builder.lua` / `error_system.lua`

**Evidence**:
- `error_system.lua` 569 LOC, `error_builder.lua` 212 LOC
- No tests found matching `error_system` or `error_builder` patterns
- `error_builder.lua` constructs localized error messages from templates
- Missing: Template interpolation with missing keys, nested error context, error code collisions

**Code Path**:
```lua
-- error_builder.lua (assumed structure)
function error_builder.build(error_code, context)
  local template = error_templates[error_code]
  return string.format(template, context.param1, context.param2)
end
```

**Invariant Risk**: ENGINEERING.md §1.1 (Error Handling Excellence) - malformed error message breaks error propagation. User sees stack trace instead of actionable message.

**Why Critical**: Error construction failure during command execution leaves `last_error_message` empty (line 238). UI displays generic "Command failed" with no details. User cannot diagnose issue.

**Existing Coverage**: None identified

---

## GAP-014: Snapshot Boundary Conditions
**Missing Coverage**: Snapshot creation at sequence boundaries (first/last frame)

**Evidence**:
- `snapshot_manager.lua` creates snapshots for undo optimization
- 3 tests found: `test_timeline_active_region_snapshot.lua`, `test_batch_ripple_dry_run_preloaded_snapshot.lua`, `test_insert_snapshot_boundary.lua`
- Missing: Snapshot at frame 0, snapshot beyond sequence duration, snapshot with empty sequence

**Code Path**:
```lua
-- snapshot_manager.lua (assumed)
function create_snapshot(db, sequence_id, sequence_number, clips)
  local snapshot_data = serialize_clips(clips)
  db:exec("INSERT INTO clip_snapshots VALUES (?, ?, ?)", sequence_id, sequence_number, snapshot_data)
end
```

**Invariant Risk**: INV-013 (Snapshot Consistency) (assumed) - snapshot at boundary doesn't include clips outside range. Undo restoration loads incomplete state.

**Why Critical**: User makes edit at frame 0, performs 100-frame ripple. Snapshot captures post-ripple state. Undo attempts to restore from snapshot but frame 0 clips missing. Timeline now empty at start.

**Existing Coverage**:
- Minimal: `test_insert_snapshot_boundary.lua` (1 test)
- Missing: Frame 0 snapshots, beyond-duration snapshots, empty sequence snapshots

---

## GAP-015: Transaction Rollback Recovery
**Missing Coverage**: Partial rollback on command execution failure

**Evidence**:
- `command_manager.lua:645` commits after successful execution
- Error path: `scope:finish("executor_error")` at line 240, then falls through to... no explicit rollback call visible
- ENGINEERING.md §1.14 mentions rollback but implementation unclear
- Zero tests simulate transaction failure between BEGIN and COMMIT

**Code Path**:
```lua
-- command_manager.lua:513-520
local begin_tx = db:prepare("BEGIN TRANSACTION")
begin_tx:exec()

-- command_manager.lua:566-578
local execution_success, error_message = execute_command_implementation(...)
if not execution_success then
  -- No explicit ROLLBACK call here
  -- Does Lua GC finalize transaction? Does next command BEGIN trigger implicit ROLLBACK?
end
```

**Invariant Risk**: INV-012 (Command Persistence) - failed command leaves transaction open. Next command's BEGIN fails with "transaction already active" error. INV-004 (Command Sequencing) - sequence number incremented (line 548) but command not persisted. Gap in sequence.

**Why Critical**: Command fails after sequence increment but before persist. Undo stack position now points to non-existent command. Subsequent undo crashes with "command not found".

**Existing Coverage**: None identified for failed transaction rollback

---

## Summary Statistics

### Coverage by Subsystem
| Subsystem | Total Tests | Critical Gaps |
|-----------|-------------|---------------|
| Command Manager | ~30 (execute/undo/redo) | 5 (GAP-001, 004, 008, 009, 015) |
| Ripple Algorithm | ~60 (batch/edge) | 2 (GAP-006, 007) |
| Database Schema | ~5 (triggers/constraints) | 2 (GAP-002, 003) |
| FFI Layer | 1 (C++) | 1 (GAP-010) |
| Error System | 0 | 1 (GAP-013) |
| Clip Links | 0 (main suite) | 1 (GAP-012) |
| State Management | ~8 (snapshot/selection) | 2 (GAP-014, concurrency partial) |
| Import | ~10 (FCP7/DRP) | 1 (GAP-011) |

### Risk Distribution
- **Correctness-Critical**: 8 gaps (001, 002, 004, 006, 009, 011, 012, 015)
- **Performance-Critical**: 2 gaps (005, 011)
- **Robustness-Critical**: 5 gaps (003, 007, 010, 013, 014)

### Highest Priority Gaps (by invariant exposure)
1. **GAP-015** - Transaction rollback (INV-004, INV-012)
2. **GAP-002** - Cascade deletes (INV-012)
3. **GAP-009** - Playhead restoration (INV-010)
4. **GAP-007** - Temp gap cleanup (INV-006, INV-009)
5. **GAP-006** - Timebase rescaling (INV-001, INV-002, INV-005)
