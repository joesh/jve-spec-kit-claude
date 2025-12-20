# 04-BEHAVIORAL-FLOWS

## Command Execution Flow

### Entry: M.execute()
**Path**: `src/lua/core/command_manager.lua:451-700`

1. **Normalize command** (lines 453-462)
   - `normalize_command()` at line 79
   - String → Command object conversion
   - Sets `project_id` from `ensure_active_project_id()` at line 72
   - Validates metatable has `Command.__index`

2. **Validate parameters** (lines 475-479)
   - `validate_command_parameters()` at line 352
   - Checks: `command.type`, `command.project_id` non-empty
   - Early return with error if invalid

3. **Check scope** (lines 481-486)
   - `command_scope.check(command)` in `src/lua/core/command_scope.lua`
   - Validates command can execute in current context
   - Returns `(ok, error_message)`

4. **Non-recording path** (lines 488-492)
   - Check `non_recording_commands` table at line 27
   - Types: `SelectAll`, `DeselectAll`, `GoToStart`, `GoToEnd`, etc.
   - Calls `execute_non_recording()` at line 419
   - No transaction, no persistence, no sequence numbering

5. **Resolve undo stack** (lines 494-507)
   - `history.resolve_stack_for_command(command)` in `src/lua/core/command_history.lua`
   - Multi-stack feature (env: `JVE_ENABLE_MULTI_STACK_UNDO`)
   - Extracts `sequence_id` from command params
   - Sets active stack via `history.set_active_stack()`

6. **Begin transaction** (lines 513-520)
   - `db:prepare("BEGIN TRANSACTION")`
   - Executes immediately
   - Early return on failure

7. **State hash (optional)** (lines 523-534)
   - Computed if: `command.suppress_if_unchanged` OR env `JVE_FORCE_STATE_HASH=1`
   - `state_mgr.calculate_state_hash()` in `src/lua/core/command_state.lua`
   - Stores `pre_hash` for no-op detection
   - Performance tracked via `create_command_perf_tracker()` at line 207

8. **Increment sequence** (lines 537-552)
   - `history.increment_sequence_number()` at `src/lua/core/command_history.lua:101`
   - Assigns `command.sequence_number`
   - Sets `command.parent_sequence_number` to current position
   - Validates parent not NULL unless first command
   - Rollback + error if undo tree corrupted

9. **Capture pre-state** (lines 556-563)
   - `timeline_state.get_playhead_position()` → stores `command.playhead_value`
   - `timeline_state.get_sequence_frame_rate()` → stores `command.playhead_rate`
   - `capture_pre_selection_for_command()` at line 358
   - Calls `state_mgr.capture_selection_snapshot()` → JSON strings
   - Sets: `command.selected_clip_ids_pre`, `selected_edge_infos_pre`, `selected_gap_infos_pre`
   - Skipped if `command.__skip_selection_snapshot`

10. **Execute implementation** (lines 566-578)
    - `execute_command_implementation()` at line 377
    - Looks up executor via `registry.get_executor(command.type)`
    - Wrapped in `xpcall` with traceback
    - Returns `(success, error_message, result_data)`
    - Performance logged if env `JVE_DEBUG_COMMAND_PERF=1`

11. **Capture post-state** (lines 579-585)
    - Only if `execution_success == true`
    - `capture_post_selection_for_command()` at line 367
    - Sets: `command.selected_clip_ids`, `selected_edge_infos`, `selected_gap_infos`

12. **No-op detection** (lines 587-610)
    - If `suppress_if_unchanged` flag set
    - Computes `post_hash` via `state_mgr.calculate_state_hash()`
    - Compares `post_hash == pre_hash`
    - If equal: `finish_as_noop()` at line 247
      - Rollback transaction
      - Decrement sequence number
      - Return success without persistence

13. **Persist command** (lines 612-623)
    - `command:save(db)` in `src/lua/command.lua`
    - Writes to `commands` table with JSON args
    - `history.set_current_sequence_number(sequence_number)` at line 622
    - `history.save_undo_position()` at line 623

14. **Snapshotting** (lines 626-643)
    - Check `command.__force_snapshot` OR `snapshot_mgr.should_snapshot()`
    - `snapshot_mgr` in `src/lua/core/snapshot_manager.lua`
    - Requires `__snapshot_sequence_ids` parameter (asserts if missing at line 630)
    - For each sequence: `snapshot_mgr.create_snapshot(db, seq_id, sequence_number, clips)`
    - Writes to `clip_snapshots` table

15. **Commit transaction** (line 645)
    - `db:exec("COMMIT")`
    - Performance logged

16. **Notify listeners** (lines 651-658)
    - `notify_command_event()` at line 42
    - Iterates `command_event_listeners` table
    - Event: `{event="executed", command=cmd, project_id=..., sequence_number=...}`

17. **Reload timeline** (lines 661-674)
    - Extract `sequence_id` from command params
    - Check for `__timeline_mutations` parameter
    - If mutations: `timeline_state.apply_mutations()` (differential update)
    - Else: `timeline_state.reload_clips()` (full reload from DB)

### Execution Implementation: execute_command_implementation()
**Path**: `src/lua/core/command_manager.lua:377-417`

1. **Get executor** (line 384)
   - `registry.get_executor(command.type)` in `src/lua/core/command_registry.lua`
   - Executor functions stored in `_G.command_executors` table
   - Loaded on-demand via `registry.load_command_module()`

2. **Execute with protection** (lines 387-404)
   - `xpcall(executor, traceback_handler, command)`
   - Executor receives command object as sole argument
   - Returns: `(success, error_message, result_data)` OR `boolean` OR `{success=bool, error_message=str}`
   - Normalize via `normalize_executor_result()` at line 138

3. **Test command fallback** (lines 405-409)
   - Types: `FastOperation`, `BatchOperation`, `ComplexOperation`
   - Used by test harness
   - Returns `true` without actual execution

4. **Unknown command** (lines 411-416)
   - Logs error via `logger.error()`
   - Sets `last_error_message`
   - Returns `false`

## Undo Flow

### Entry: M.undo()
**Path**: `src/lua/core/command_manager.lua:1213-1225` → `execute_undo()`

**Note**: There is no standalone `M.undo()` function in the visible range. Undo is triggered via `M.execute_undo()` at line 1127.

### execute_undo() Flow
**Path**: `src/lua/core/command_manager.lua:1127-1211`

1. **Get original command** (implicit, caller provides `original_command`)
   - Command object from `commands` table
   - Retrieved via `M.get_command_at_sequence()` at line 959

2. **Create undo command** (line 1130)
   - `original_command:create_undo()` in `src/lua/command.lua`
   - Sets `type = "Undo" .. original_command.type`
   - Copies parameters

3. **Get undoer** (lines 1133-1143)
   - `registry.get_undoer(original_command.type)`
   - Stored in `_G.command_undoers` table
   - Auto-load if missing: `registry.load_command_module("Undo" .. type)`
   - Hard fail if still missing (assert at line 1139)

4. **Execute undoer** (lines 1147-1158)
   - `pcall(undoer, original_command)`
   - Undoer receives original command (not undo command)
   - Returns same format as executor
   - Normalize result

5. **On success** (lines 1162-1203)
   - Set `result.success = true`
   - Serialize undo command
   - Move history pointer: `history.set_current_sequence_number(original_command.parent_sequence_number)` at line 1166
   - Save position: `history.save_undo_position()` at line 1167
   - Restore pre-selection: `state_mgr.restore_selection_from_serialized(selected_*_pre)` at line 1169
   - Apply mutations from `__timeline_mutations` parameter (lines 1172-1191)
   - If mutations: `timeline_state.apply_mutations()` (differential)
   - Else: `timeline_state.reload_clips()` (full reload)
   - Restore playhead: `timeline_state.set_playhead_position()` at line 1194
   - Notify listeners: `notify_command_event({event="undo"})` at line 1199

6. **On failure** (lines 1204-1208)
   - Set `result.error_message`
   - Log error via `logger.error()`

## Redo Flow

### Entry: M.redo() → M.redo_to_sequence_number()
**Path**: `src/lua/core/command_manager.lua:1115-1125` → `1088-1113`

1. **Check can redo** (line 1117)
   - `M.can_redo()` checks if children exist in undo tree
   - Get `current_sequence_number` from `history` module

2. **Find next command** (lines 1118-1121)
   - `history.find_latest_child_command(parent)`
   - Returns child with highest sequence number
   - Delegates to `M.redo_to_sequence_number()`

### redo_to_sequence_number() Flow
**Path**: `src/lua/core/command_manager.lua:1088-1113`

1. **Validate target** (lines 1089-1091)
   - Must be `> 0` and `type == "number"`

2. **Load command** (lines 1093-1096)
   - `M.get_command_at_sequence(target_sequence_number, active_project_id)` at line 959
   - Reconstructs command from `commands` table
   - Returns `nil` if not found

3. **Verify parent** (lines 1098-1109)
   - `expected_parent = history.get_current_sequence_number()`
   - `actual_parent = cmd.parent_sequence_number`
   - Must match or error
   - Prevents redo on wrong branch

4. **Execute redo** (line 1112)
   - `execute_redo_command(cmd)` at line 1017

### execute_redo_command() Flow
**Path**: `src/lua/core/command_manager.lua:1017-1086`

1. **Get executor** (implicit, similar to execute)
   - Uses same `registry.get_executor()` lookup
   - Executes forward implementation again

2. **Execute with protection** (similar to line 387-404 in execute)
   - Same `xpcall` pattern
   - Returns normalized result

3. **On success**
   - Move history pointer: `history.set_current_sequence_number(cmd.sequence_number)` at line 1052
   - Save position: `history.save_undo_position()` at line 1053
   - Restore post-selection: `state_mgr.restore_selection_from_serialized(selected_*_post)` at line 1054
   - Apply mutations: `timeline_state.apply_mutations()` OR `reload_clips()`
   - Notify listeners: `notify_command_event({event="redo"})`

## Timeline Reload Flow

### Entry: timeline_core_state.reload_clips()
**Path**: `src/lua/ui/timeline/state/timeline_core_state.lua:68-87`

**Note**: Function not visible in provided range. Tracing via init().

### init() Flow (Includes Reload)
**Path**: `src/lua/ui/timeline/state/timeline_core_state.lua:201-350`

1. **Persist pending state** (line 203)
   - `M.persist_state_to_db(true)` if `persist_dirty` flag set
   - Ensures no data loss on sequence switch

2. **Validate sequence_id** (lines 205-206)
   - Assert non-empty
   - Store in `data.state.sequence_id`

3. **Load data from DB** (lines 209-211)
   - `db.load_tracks(sequence_id)` → `data.state.tracks`
   - `db.load_clips(sequence_id)` → `data.state.clips`
   - `clip_state.invalidate_indexes()` clears spatial caches

4. **Verify project ownership** (lines 214-232)
   - Query: `SELECT project_id FROM sequences WHERE id = ?`
   - Assert sequence has project_id in DB
   - If `project_id` argument provided, assert match
   - Store in `data.state.project_id`

5. **Load sequence settings** (lines 234-297)
   - Query: `SELECT playhead_frame, selected_clip_ids, selected_edge_infos, view_start_frame, view_duration_frames, fps_numerator, fps_denominator, mark_in_frame, mark_out_frame FROM sequences WHERE id = ?`
   - Column indices: `SEQ_COL_*` constants at lines 95-108
   - **Frame rate** (lines 238-245)
     - Assert `fps_numerator` and `fps_denominator` not NULL
     - Error: `"FATAL: Sequence has NULL frame rate in database"`
     - Store in `data.state.sequence_frame_rate`
   - **Playhead** (lines 252-253)
     - `saved_playhead = query:value(SEQ_COL_PLAYHEAD)`
     - `Rational.new(saved_playhead or 0, fps_num, fps_den)`
   - **Selected clips** (lines 256-266)
     - Decode JSON: `json.decode(saved_sel)`
     - Lookup each `clip_id` via `clip_state.get_by_id()`
     - Rebuild `data.state.selected_clips` array
   - **Selected edges** (lines 269-297)
     - Decode JSON: `json.decode(saved_edges)`
     - For each edge: lookup `clip_id`
     - Handle temp gaps: `resolve_gap_clip_id()` at line 49
     - Temp gap IDs: `"temp_gap_{track_id}_{start_frames}_{end_frames}"`
     - If gap edge, resolve to adjacent clip
     - Clear selected clips if edges present

6. **Load track heights** (lines 310-350)
   - Query: `SELECT track_heights_json FROM sequence_track_layouts WHERE sequence_id = ?`
   - Decode JSON: `json.decode(heights_json)`
   - Apply to `data.state.tracks` array
   - If missing, load template from `project_settings`
   - Template: `{video=[h1,h2,...], audio=[h1,h2,...]}`

7. **Notify listeners** (implicit)
   - `data.notify_listeners()` in `src/lua/ui/timeline/state/timeline_state_data.lua`
   - Triggers UI repaint

### database.load_clips() Flow
**Path**: `src/lua/core/database.lua:684-732`

1. **Validate parameters** (lines 685-687)
   - Error if `sequence_id == nil`

2. **Check connection** (lines 689-691)
   - Error: `"FATAL: No database connection"`

3. **Prepare query** (lines 693-717)
   - SQL: `SELECT c.*, t.sequence_id, m.name, m.file_path, s.fps_numerator, s.fps_denominator FROM clips c JOIN tracks t ... WHERE t.sequence_id = ?`
   - Joins: `tracks`, `sequences`, `LEFT JOIN media`
   - Order: `timeline_start_frame ASC`
   - Error: `"FATAL: Failed to prepare clip query"`

4. **Execute query** (lines 719-729)
   - Bind `sequence_id` parameter
   - Iterate rows: `while query:next()`
   - Build clip: `build_clip_from_query_row(query, sequence_id)`
   - Accumulate in `clips` array

5. **Build clip object** (implicit, separate function)
   - Constructs Rational times from DB integers
   - Fields: `timeline_start`, `duration`, `source_in`, `source_out`
   - Each as `Rational.new(frames, fps_num, fps_den)`

6. **Return clips** (line 731)
   - Array of clip objects
   - Empty array if no results

## Batch Ripple Flow

### Entry: batch_ripple_edit.execute()
**Path**: `src/lua/core/commands/batch_ripple_edit.lua`

**Note**: Full execute function not in visible range. Tracing via pipeline.

### Pipeline Flow
**Path**: `src/lua/core/ripple/batch/pipeline.lua:5-36`

Called from `batch_ripple_edit.execute()` → `batch_pipeline.run(ctx, db, ops)`

1. **Resolve sequence rate** (line 9)
   - `prepare.resolve_sequence_rate(ctx, db)` in `src/lua/core/ripple/batch/prepare.lua`
   - Queries sequence FPS from DB
   - Stores in `ctx.seq_fps_num`, `ctx.seq_fps_den`

2. **Resolve delta** (lines 10-12)
   - `prepare.resolve_delta(ctx)` in `prepare.lua`
   - Validates `ctx.delta_frames` is integer
   - Returns `false` if invalid

3. **Snapshot edges** (line 14)
   - `prepare.snapshot_edge_infos(ctx)` in `prepare.lua`
   - Copies `ctx.edge_infos` to `ctx.original_edge_infos`
   - Preserves original state for undo

4. **Build clip cache** (line 17)
   - `ops.build_clip_cache(ctx)` in `batch_ripple_edit.lua`
   - Loads all clips from DB
   - Builds `ctx.clip_lookup` hash table: `{[clip_id] = clip_obj}`

5. **Prime neighbor cache** (line 18)
   - `ops.prime_neighbor_bounds_cache(ctx)` in `batch_ripple_edit.lua`
   - Calls `build_neighbor_bounds_cache()` from `src/lua/core/ripple/track_index.lua`
   - Builds spatial index: `{[track_id] = sorted_clips}`

6. **Materialize gap edges** (line 19)
   - `ops.materialize_gap_edges(ctx)` in `batch_ripple_edit.lua`
   - Converts gap edges (`gap_after`, `gap_before`) to synthetic clips
   - Calls `create_temp_gap_clip()` at line 90
   - Temp clip ID: `"temp_gap_{track_id}_{start}_{end}"`
   - Adds to `ctx.clip_lookup`

7. **Assign edge tracks** (line 20)
   - `ops.assign_edge_tracks(ctx)` in `batch_ripple_edit.lua`
   - For each edge: extract `track_id` via `get_edge_track_id()`
   - Groups edges by track

8. **Determine lead edge** (line 21)
   - `ops.determine_lead_edge(ctx)` in `batch_ripple_edit.lua`
   - First selected edge becomes lead
   - Lead edge determines ripple direction
   - Stores in `ctx.lead_edge_info`

9. **Analyze selection** (line 22)
   - `ops.analyze_selection(ctx)` in `batch_ripple_edit.lua`
   - Classifies each edge: ripple vs roll
   - Ripple: one side selected
   - Roll: both sides selected

10. **Compute constraints** (line 23)
    - `ops.compute_constraints(ctx, db)` in `batch_ripple_edit.lua`
    - Media limits: source in/out bounds
    - Collision detection: downstream clips
    - Clamps delta to prevent violations

11. **Process edge trims** (line 24)
    - `ops.process_edge_trims(ctx, db)` in `batch_ripple_edit.lua`
    - Trim selected clip edges by delta
    - Updates: `timeline_start_frame`, `duration_frames`, `source_in_frame`, `source_out_frame`
    - Stores mutations in `ctx.mutations`

12. **Compute downstream shifts** (lines 29-32)
    - `ops.compute_downstream_shifts(ctx, db)` in `batch_ripple_edit.lua`
    - Find all clips starting at or after edge boundary
    - Shift by delta: `timeline_start_frame += delta`
    - Check for collisions
    - If collision: return `(false, adjusted_frames)`
    - If collision: `ops.retry_with_adjusted_delta()` at line 31

13. **Build planned mutations** (line 34)
    - `ops.build_planned_mutations(ctx)` in `batch_ripple_edit.lua`
    - Aggregates all mutations: inserts, updates, deletes
    - Groups by sequence_id
    - Format: `{sequence_id=..., inserts=[...], updates=[...], deletes=[...]}`

14. **Finalize execution** (line 35)
    - `ops.finalize_execution(ctx, db)` in `batch_ripple_edit.lua`
    - Applies mutations to DB via `clip_mutator.apply_mutations()`
    - Returns `(success, error_message)`

## Event Sourcing Replay

### Entry: command_manager.replay_from()
**Path**: Referenced but not visible in provided range

**Flow** (inferred from architecture):

1. **Load commands**
   - Query: `SELECT * FROM commands WHERE sequence_number >= ? AND command_type NOT LIKE 'Undo%' ORDER BY sequence_number`
   - Reconstruct command objects

2. **Execute in order**
   - For each command: `M.execute(command)`
   - Skip undo/redo markers
   - Apply mutations sequentially

3. **Restore final state**
   - Timeline reloaded at end
   - Selection/playhead restored from last command

## Key Observations

### Transaction Boundaries
- Commands execute inside single DB transaction
- Transaction: BEGIN (line 513) → COMMIT (line 645)
- Rollback on: validation failure, execution failure, no-op detection

### Cache Invalidation
- `clip_state.invalidate_indexes()` called on every reload
- Spatial indexes rebuilt on next query
- No incremental cache updates visible

### Selection Restoration
- Pre-selection stored before execute
- Post-selection stored after execute
- Undo restores pre-selection
- Redo restores post-selection
- Temp gap IDs resolved to real clips on reload

### Mutation Application
- Two paths: `apply_mutations()` (differential) vs `reload_clips()` (full)
- Mutations checked in `__timeline_mutations` parameter
- Differential: apply inserts/updates/deletes to in-memory state
- Full: reload entire clip list from DB
- Mutation path preferred but falls back to full reload

### Error Propagation
- `xpcall` wraps all executor calls
- Traceback captured on error
- Stored in `last_error_message` module variable
- Logged via `logger.error()`
- Transaction rolled back on error

### Performance Tracking
- Env: `JVE_DEBUG_COMMAND_PERF=1` enables logging
- Tracks: state hashing, execution, DB commit, snapshotting
- Logs: `"phase took X.XXms (cmd=Type seq=N)"`
- Uses `os.clock()` for microsecond precision

### Undo Tree Navigation
- Parent links: `commands.parent_sequence_number`
- Children found via query
- Jump to arbitrary point: `M.jump_to_sequence_number()`
- Algorithm: undo to LCA, redo to target
- LCA: Lowest Common Ancestor in undo tree
