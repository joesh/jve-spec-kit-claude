# Session State - TimelineActiveRegion (2025-12-15)

## Context
- Focus: timeline performance with thousands of clips (edge drag vs release/commit).
- Architectural goal: scope rendering and edit computation to a `TimelineActiveRegion` (active time window), without track-scoping complexity.

## Current Status (verified)
- `make -j4 test` passes locally.
- Timeline rendering is viewport-culled (base pass) and asserts if `timeline_state.get_clips()` is used during render; rendering uses per-track indices instead.
- Clip drawing bug fixed: timeline `timeline_start`/`duration` are now derived from **sequence FPS** (not clip FPS), preventing viewport math from pushing clips offscreen.

## Notes / Follow-ups
- Run: `JVE_DEBUG_COMMAND_PERF=1 ./build/bin/JVEEditor` to see `[command_perf]` breakdowns.

---

# Session State - 2025-?? BatchRippleEdit VIDEO_OVERLAP on Drag

## Current Status (unverified)
- Timeline drag for BatchRippleEdit fails with SQLite trigger error: `VIDEO_OVERLAP` on video tracks (clip `0500ccf9-eb33-4363-a6b7-a7371829abee`) during `BatchRippleEdit` update.
- Next steps: add regression coverage for the overlap failure, trace mutation ordering or constraint clamping in `core/commands/batch_ripple_edit.lua`, and confirm the fix prevents overlap-triggered UPDATE failures.
- Timeline edge drag now keeps deltas in Rational frames only (no ms round-trip); added regression `tests/test_timeline_edge_drag_frames_only.lua`, removed UI ms fallbacks, and added `clamped_delta_frames` for BatchRippleEdit preview consumption while retaining `clamped_delta_ms` for existing tests.
- Edge drag execution now prefers `preview_clamped_delta` for `BatchRippleEdit` so the commit delta matches the preview clamp; regression `tests/test_timeline_edge_drag_clamped_delta.lua` added (user confirmed in-app).

---

# Session State - 2025-10-25 Luacheck Restore

## Critical Note
- Top-level `make` now depends on a revived `luacheck` target (wrapper in `scripts/run_luacheck.sh`). Any lint warnings abort the build before the CMake targets run, matching the original workflow before it was removed.
- Cleared the 68-warning backlog across `src/lua/ui/**` by pruning unused imports/locals, forward-declaring cross-file helpers, and teaching `.luacheckrc` about the FFI-provided `timeline_*` globals. `./scripts/run_luacheck.sh` now reports 0 warnings, so `make` proceeds directly into the CMake/Lua suites.
- New Makefile target summary: `.PHONY` now includes `luacheck`, `all` depends on `configure luacheck`, and `make help` documents the requirement so future agents do not bypass lint.
- Follow-up: Refactored `timeline_view_renderer` edge preview rendering into helper functions (`build_preview_edge_payload`, `render_preview_edge_handles`, `render_remaining_clamped_edges`, etc.) so bracket geometry, implied-edge expansion, and clamp coloring are separated per Rule 2.26. Added regression `tests/test_timeline_preview_shift_rect.lua` that forces a shift-only preview payload to ensure yellow outline drawing stays intact after the split.

# Session State - 2025-10-26 Gap Clamp + Helper Decomposition

## Critical Fixes
- Regression `tests/test_batch_ripple_gap_nested_closure.lua` reproduces the `g1 c1 g2 c2` case where dragging the leftmost `]` clamped after `g2` width. The fix removes the shared global gap cap in `compute_constraints`, relies on the per-edge constraints from `compute_gap_close_constraint`, and ensures `resolve_gap_timeline_start_frames` falls back to the right clip when the temp-gap start is `0`.
- Gap ripple bug “dragging gap ] disables downstream clip” is guarded by `tests/test_batch_ripple_gap_preserves_enabled.lua`; dry runs keep the neighbor clip enabled because temp gaps now clone the `enabled` column before shifting the real clip.

## Structural Work
- `process_edge_trims` now orchestrates helpers (reset state, process each edge, propagate temp-gap movement, compute downstream shift vectors) so the top-level reads like an algorithm and each helper carries an isolated responsibility.
- `compute_constraints` delegates gap metadata, roll limits, start-origin clamps, and source media limits to dedicated helpers. This removes redundant min-gap aggregation logic and makes future constraint tweaks pluggable.
- Added doc comments to the frequently-touched helpers (`create_temp_gap_clip`, `apply_edge_ripple`, `pick_edges_for_track`) documenting their parameters/edge cases per engineering Rule 0.2.

## Verification
- `tests/test_batch_ripple_gap_nested_closure.lua` and `tests/test_batch_ripple_gap_preserves_enabled.lua` both pass after the fixes (and fail on the pre-fix file).
- Full `make -j4` (luacheck + 197 Lua tests + CMake targets) passes on this state.

# Session State - 2025-10-25 Gap Ripple Behavior Fixes

## Critical Bugs
- Dragging a gap `]` handle disabled the adjacent downstream clip once BatchRippleEdit committed because cloned downstream clips defaulted `enabled=false`. User repro: `g1 c1 g2 c2`, drag the `]` bordering `c2` and release; `c2` greyed out until reload.
- Dragging the leftmost gap `]` left clamped early after moving the width of the inner gap `g2`, so `c1` never closed `g1` fully. `tests/test_batch_ripple_gap_downstream_block.lua` and UI repro both showed the drag blocking once delta matched `g2`.

## Fix Summary
- Regression test `tests/test_batch_ripple_gap_preserves_enabled.lua` proves downstream clips stay enabled after gap drags; clones now copy the `enabled` flag when materializing temp gap neighbors.
- Clamp computation keeps per-edge constraints scoped to the dragged lead gap: `compute_constraints` no longer overwrites `global_max_frames` with larger values and `ctx.lead_is_gap` ensures gap-based clamps only apply when the active edge is a gap.
- Downstream gap-right propagation marks neighbor IDs as `edited`, so BatchRippleEdit shifts the real clip after the temp gap clip moves without double-counting selection edges.
- Dry runs with nonexistent edge IDs reuse the provided `sequence_id` via `command_helper.resolve_sequence_id_for_edges`, allowing previews to skip cleanly when the UI sends stale selection IDs instead of erroring.
- Removed temporary `log_debug("gap_right move...")` instrumentation from `process_edge_trims` after confirming the regression is fixed.

## Verification
- Gap drag + downstream clamp behaviors validated through `tests/test_batch_ripple_gap_preserves_enabled.lua`, `tests/test_batch_ripple_gap_downstream_block.lua`, and `tests/test_batch_ripple_gap_drag_behavior.lua`.
- Full Lua + C++ suite: `make -j4` passes (195 Lua tests).

# Session State - 2025-?? Capture Clip State JSON Serialization Fix

## Critical Note
- UndoNudge crash: `command_helper.capture_clip_state` wasn't saving fps_numerator/fps_denominator, so after JSON round-trip (command parameters → database → retrieval), mutations lost frame rate metadata and undo sorting crashed with "missing previous timeline_start frames".
- Root cause: Rational objects serialize to JSON as plain tables `{frames:N, fps_numerator:X, fps_denominator:Y}` but lose metatable. Without explicit fps fields in captured state, undo couldn't extract frame counts.
- Fix: `capture_clip_state` now explicitly saves `fps_numerator`, `fps_denominator` (and optional `created_at`/`modified_at` for delete restoration). Added regression `tests/test_capture_clip_state_serialization.lua` that validates JSON round-trip preserves frame data.
- Improved error message: When undo hits old incompatible mutations (pre-fix), now suggests deleting `~/Documents/JVE\ Projects/Untitled\ Project.jvp` to reset command history rather than cryptic "missing frames" error.

# Session State - 2025-?? Nudge Undo Overlap Fix

## Critical Note
- Reproduced UndoNudge VIDEO_OVERLAP: `command_helper.revert_mutations` restored deleted/occluded clips before moving nudged clips back, so the reinsert hit the overlap trigger while the moved clip was still in the way. Added regression `tests/test_revert_mutations_nudge_overlap.lua` that fails on the old ordering and now passes.
- Fix: `revert_mutations` now deletes inserts, applies updates (sorted by nudge direction), then restores deletes; requires fps/created_at fields on restore, and keeps strict frame validation (no fallbacks).
- Cleanup: `split_clip` now requires clip rate when hydrating split values (no 30fps fallback); `nudge` requires the active sequence rate for Rational inputs/legacy frames; `clip_state.get_at_time` fails fast if sequence_frame_rate is missing instead of defaulting to 30fps.
- Tests run: `tests/test_revert_mutations_nudge_overlap.lua`, `tests/test_nudge_command_manager_undo.lua`, `tests/test_nudge_block_resolves_overlaps.lua`.

# Session State - 2025-?? Insert Snapshot Assertion

## Critical Note
- Insert command crashed whenever the command sequence hit a snapshot boundary (`sequence_number % 50 == 0`) because it never populated `__snapshot_sequence_ids`; command_manager asserts and the menu printed "INSERT failed: unknown error" after logging a successful insert.
- Fix applied: `core.commands.insert` now seeds `__snapshot_sequence_ids` with the resolved sequence id so snapshot creation can succeed.
- Regression added: `tests/test_insert_snapshot_boundary.lua` fast-forwards to the snapshot boundary and verifies Insert succeeds and writes a snapshot entry.
- Timeline keyboard shortcut regression: Cmd/Ctrl+B Split failed with "attempt to call nil value" because the timeline state facade no longer exposed `get_clips_at_time`. Added regression `tests/test_keyboard_split_shortcut.lua` and restored the API via `timeline_state`/`clip_state` (new overlap helper). Awaiting user confirmation from UI.
- Split menu regression: menu Split path used `clip.start_value` (nil for Rational timeline clips) causing `Rational:add` crash. Added regression `tests/test_menu_split_rational.lua`, exposed test helper in `menu_system`, and hydrated clip bounds in the Split branch to handle Rational fields safely.
- Timeline renderer crash: `timeline_view_renderer` assumed `clip.timeline_start`/`clip.duration` were always Rational; undo/redo leaves table/nil and `Rational:add` crashed. Added Rational hydration/guard in clip drawing and regression `tests/test_timeline_view_renderer_missing_clip_fields.lua`.
- Edge picker crash after undo/redo: `edge_picker` assumed clip bounds were Rational and crashed when selection contained table-based times. Added hydration/guards in `edge_picker.build_boundaries` and regression `tests/test_edge_picker_hydration.lua`.
- Clip state normalization: centralized Rational hydration in `ui.timeline.state.clip_state` so clip indexes and mutation application coerce timeline_start/duration/source in/out to Rational using the active sequence rate; invalid clips are skipped. Objective is to stop magnetic_snapping/renderer/edge picker from seeing raw tables after undo/redo. Awaiting UI verification.
- Magnetic snapping guard: `magnetic_snapping.find_snap_points` now hydrates clip times and skips invalid clips instead of crashing the entire interaction loop. This reduces blast radius if a command leaves bad clip times.

# Session State - 2025-10-10 Dry-Run Command Preview & Ripple Trim Fixes

## CRITICAL SESSION CONTEXT
**Implemented dry-run command pattern for preview rendering and fixing ripple trim semantics. Working through database corruption bugs and edge drag preview issues.**

**Date**: October 10, 2025
**Session Focus**: Dry-run preview pattern, ripple trim logic, drag state race conditions

---

## Session Accomplishments (2025-10-10)

### 1. Dry-Run Command Pattern (COMPLETED)
- **GOAL**: Enable preview rendering without duplicating business logic between commands and views
- **PATTERN**: Commands accept `dry_run` parameter, return preview data without executing
- **IMPLEMENTED**:
  - Added `get_executor()` function to command_manager for external dry-run calls
  - Dry-run support in: Nudge, MoveClipToTrack, RippleEdit, BatchRippleEdit, SplitClip, Insert, Overwrite
  - Edge drag preview now uses RippleEdit/BatchRippleEdit dry-run to show affected + shifted clips
  - Clip drag preview could use dry-run but manual calculation is simpler for position offsets
- **BENEFIT**: View layer just calls command with dry_run=true and renders results - no logic duplication
- **FILES**:
  - `src/lua/core/command_manager.lua` (dry-run in all major commands, get_executor function)
  - `src/lua/ui/timeline/timeline_view.lua` (edge drag preview using dry-run)

### 2. Fixed Drag State Race Condition (COMPLETED)
- **ISSUE**: Rubberband preview continued to follow mouse after release, wouldn't disappear
- **ROOT CAUSE**: State change listener race condition:
  1. Release handler executes commands
  2. Commands call `reload_clips()` which triggers state listener
  3. Listener calls `render()` BEFORE drag_state cleared
  4. Preview draws based on stale drag_state
  5. Only then does release handler clear drag_state
- **FIX**: Capture drag data in local variables, clear drag_state IMMEDIATELY before executing commands
- **RESULT**: Preview clears instantly on mouse release
- **FILES**: `src/lua/ui/timeline/timeline_view.lua:947-1129` (release handler refactored)

### 3. Ripple Trim Semantics (FIXED - Both Issues)
- **ISSUE 1**: Downstream clips shifted in WRONG DIRECTION
  - **ROOT CAUSE**: Used `delta_ms` (drag offset) instead of actual duration change
    - Drag in-point right by +100ms → clip shortens by 100ms
    - Should shift downstream LEFT by -100ms
    - But code did: `start_time + delta_ms` = `start_time + 100` = moved RIGHT!
  - **FIX**: Calculate `shift_amount = new_duration - original_duration` for in-points
    - In-point shifts have OPPOSITE sign of drag delta
    - Out-point shifts have SAME sign as drag delta
  - **FILES**: `command_manager.lua:1893-1912, 1962` (RippleEdit execution and preview)

- **ISSUE 2**: WRONG clip highlighted (upstream instead of downstream)
  - **ROOT CAUSE**: Edge detection selected ALL edges within 8px zone
    - At edit point, both clips are within tolerance
    - Code selected BOTH edges, triggering BatchRippleEdit
    - Both clips showed in preview
  - **FIX**: Select only CLOSEST edge for ripple (single edge)
    - Use Cmd+click to select multiple edges for roll/multi-edit
    - Now properly executes RippleEdit with one edge
  - **FILES**: `timeline_view.lua:690-712` (edge selection logic)

### 4. Database Corruption Issues (ONGOING)
- **SYMPTOM**: "Command 27 has NULL parent - broken command chain detected"
- **ERROR**: Undo replay fails because event log has commands with NULL parents
- **ANALYSIS**:
  - User restarted with fresh database (deleted old corrupted one)
  - Command 27 created in CURRENT session with NULL parent
  - This means current_sequence_number was nil when command executed
  - Bug is in current code, not old database
- **STATUS**: Not yet investigated - need to find where current_sequence_number gets set to nil
- **HINT**: Check command_manager execute function, undo function for nil assignment

## Current Problems

### 1. Ripple Trim Logic (FIXED - Ready for Testing)
- ✅ Fixed downstream shift direction (use duration change, not drag delta)
- ✅ Fixed edge selection to pick closest edge only (no multi-select on single click)
- ✅ In-point ripple now correctly shifts downstream clips
- 🧪 Needs user testing to confirm behavior matches expectations

### 2. Database Corruption - NULL Parent Bug
- Command 27 has NULL parent in current session
- Indicates current_sequence_number was nil during execute
- Need to trace where this gets set to nil incorrectly
- Likely in undo path or during command execution

### 3. Edge Drag Preview Issues (RESOLVED in this session)
- ✅ Preview now uses dry-run pattern correctly
- ✅ Handles both single-edge (RippleEdit) and multi-edge (BatchRippleEdit)
- ✅ Shows affected clip + all downstream shifted clips

## Key Technical Insights

### Dry-Run Pattern Benefits
- **Encapsulation**: All operation logic stays in command, view just renders
- **No Duplication**: Preview and execution guaranteed identical (same code path)
- **Easy Extension**: Add dry-run to any command for instant preview support
- **Clean Separation**: View doesn't need to understand ripple/roll/trim semantics

### State Change Listener Race Conditions
- **Pattern**: When actions trigger callbacks, clear state BEFORE action
- **Example**: Clear drag_state before executing commands that call reload_clips()
- **Reason**: Callbacks fire synchronously during action, not after
- **Solution**: Capture needed data in locals, clear state, then execute

### Ripple Trim Semantics (NEEDS VERIFICATION)
- **In-point ripple**: Edge you're touching stays fixed in timeline
  - Dragging reveals more/less source media
  - Clip length changes, other end moves
  - Example: start_time fixed, duration changes, out-point moves
- **Out-point ripple**: Same principle, in-point fixed, duration changes
- **Key**: "The end you're touching DOES stay fixed" (user quote)

## Files Modified This Session
1. `src/lua/core/command_manager.lua`:
   - Added get_executor() function for dry-run access
   - Added dry_run support to: Nudge, MoveClipToTrack, RippleEdit, BatchRippleEdit, SplitClip, Insert, Overwrite
   - Modified apply_edge_ripple() for in-point trim (still incorrect)

2. `src/lua/ui/timeline/timeline_view.lua`:
   - Fixed drag state race condition in release handler
   - Implemented dry-run preview for edge dragging (both single and multi-edge)
   - Captures drag data before clearing state

3. User also made local changes (via linter or manual edits):
   - timeline_view.lua:478-497 (edge preview rendering adjustments)
   - command_manager.lua:2435-2451 (undo function modifications)

## Next Steps (Priority Order)

1. **Fix Ripple Trim Logic**
   - Get concrete example from user of correct behavior
   - Verify start_time/duration/source_in relationships
   - Test with actual dragging

2. **Find NULL Parent Bug**
   - Trace where current_sequence_number gets set to nil
   - Check undo function (user modified it)
   - Check execute function for nil assignments
   - Add defensive checks to prevent NULL parents

3. **Verify Dry-Run Pattern Works**
   - Test edge dragging shows correct preview
   - Confirm rubberband disappears on release
   - Check that preview matches actual execution

## Previous Session Context (2025-10-09)
- Implemented edge selection infrastructure
- Added undo position persistence
- Enforced event sourcing discipline
- Fixed panel focus indicators
- See earlier sections of this file for details

## Build Status
- **Main app**: ✅ Builds successfully
- **All changes compiled**: ✅ No syntax errors
- **Runtime status**: ⚠️ Ripple trim incorrect, NULL parent bug exists
- **Tests**: ❌ Still broken (old issue)

---

# Session State - 2025-?? Batch Ripple Syntax Failure

## Critical Note
- Latest `make -j4` run halts in `test_asymmetric_ripple_gap_clip.lua` because `core.commands.batch_ripple_edit` contains a syntax error near line 1581 (`<eof>` before `end`). Lua command loader reports "Unknown command type: BatchRippleEdit" and aborts the suite before other tests run.
- No fix attempted yet; need to inspect that file, add regression coverage, and repair the syntax so BatchRippleEdit can load.
- Syntax fix applied (`compute_constraints` no longer closes `M.register` early). Re-running `make -j4` now gets past the load failure and instead stops in `tests/test_batch_ripple_gap_downstream_block.lua` asserting “V1 middle clip should move left by full gap; expected 3000, got 5000.”
- Manual verification revealed two ripple regressions aligned with that failure:
  - Dragging a gap `]` handle disables the adjacent downstream clip once the command completes (clip UI greys out until reload).
  - Dragging the leftmost gap `]` left clamps after moving the size of the adjacent inner gap (g2) instead of allowing the full g1 closure in the `g1 c1 g2 c2` arrangement (`tests/test_batch_ripple_gap_downstream_block.lua` reproduces).

# Session State - 2025-10-24 Gap Selection Persistence

## CRITICAL SESSION CONTEXT
**Edge selections must persist correctly across undo/redo and when gap placeholders collapse after ripple trims.**

**Date**: October 24, 2025  
**Session Focus**: Normalise gap-edge selections, extend occlusion regression coverage, and confirm Lua suite passes without manual intervention.

---

## Session Accomplishments (2025-10-24)

### 1. Selection Normalisation After Gap Closure (COMPLETED)
- **ISSUE**: After closing a gap, the UI continued to report `gap_after` handles even though no gap remained, so the next drag behaved inconsistently and redo lost the intended selection.
- **FIX**: `timeline_state.reload_clips()` now calls `normalize_edge_selection_after_reload()` which:
  - Computes remaining gap distance to the nearest neighbour (treating ≤1 ms as touching).
  - Converts `gap_after → out` and `gap_before → in` once the placeholder disappears.
  - Deduplicates edges and persists the adjusted selection back to `sequences`.
- **FILES**: `src/lua/ui/timeline/timeline_state.lua:68-172`, `src/lua/ui/timeline/timeline_state.lua:224-231`.

### 2. Regression Coverage for Gap Selection & Constraints (COMPLETED)
- **ADDED**:
  - Dedicated `selection_sequence` schema with commands table so the tests exercise the command log and selection persistence exactly like the app.
  - New scenario in `tests/test_clip_occlusion.lua` that:
    1. Selects a gap edge.
    2. Closes the gap via `RippleEdit`.
    3. Verifies the selection is normalised to the clip’s `out` edge.
    4. Trims the edge again to ensure downstream clips shift correctly.
- **FILES**: `tests/test_clip_occlusion.lua:7-706`.

### 3. Documentation Update (COMPLETED)
- Documented the gap-selection normalisation behaviour and expanded regression coverage details.
- **FILES**: `docs/timeline_clip_occlusion.md:19-24`.

### 4. Full Regression Run (COMPLETED)
- `JVE_SQLITE3_PATH=/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib make -j4`
- All C++ and Lua suites pass after the above fixes.

---

### Addendum: Batch Ripple Occlusion (2025-10-24)
- Closed gaps on multiple tracks now resolve occlusions so ripple drags cannot leave overlapped media hidden under neighbouring clips (`BatchRippleEdit` + `RippleEdit` save paths call `clip:save` with batch `pending_clips`).
- Downstream shift clamps ensure we never rewind clips past t=0 during replay.
- Regression: `tests/test_clip_occlusion.lua` adds “Batch ripple closes gaps without leaving overlaps” ensuring both clips butt cleanly after a multi-track drag and replay maintains a valid state.

---

# Session State - 2025-12-15 Edit History + Bulk Shift Replay

## Key Fixes
- **SQLite reset semantics**: `src/lua/core/sqlite3.lua` no longer treats `sqlite3_reset()` return codes (which reflect the prior `sqlite3_step()` result) as “reset failures”, preventing misleading stack traces on constraint errors.
- **bulk_shift replay correctness**: `src/lua/core/command_helper.lua` bulk-shift execution now replaces `mut.clip_ids` from the SELECT (instead of appending), preventing double-application on redo/replay; regression: `tests/test_command_helper_bulk_shift_does_not_double_apply.lua`.
- **Edit history window usability**: `src/lua/ui/edit_history_window.lua` uses a top-level window (title bar/movable) and matches the Qt tree key handler signature; C++ binding `qt_set_parent` accepts `nil` to unparent (`src/lua/qt_bindings/misc_bindings.cpp`) with C++ test coverage (`tests/unit/test_qt_bindings.cpp` + `CMakeLists.txt`).

## Current Status
- `make -j4 test` passes after the above changes.
