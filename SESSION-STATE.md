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
- Closed gaps on multiple tracks now resolve occlusions so ripple drags cannot leave overlapped media hidden under neighbouring clips (`BatchRippleEdit` + `RippleEdit` save paths pass `resolve_occlusion = true`).
- Downstream shift clamps ensure we never rewind clips past t=0 during replay.
- Regression: `tests/test_clip_occlusion.lua` adds “Batch ripple closes gaps without leaving overlaps” ensuring both clips butt cleanly after a multi-track drag and replay maintains a valid state.
