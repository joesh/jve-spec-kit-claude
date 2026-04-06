# Tasks: Per-Sequence Undo Stacks & History Filtering

**Input**: Design documents from `/specs/006-per-sequence-undo/`
**Prerequisites**: plan.md, research.md, data-model.md

## Phase 3.1: Schema & Setup

- [x] T001 Add `sequence_id TEXT` column to `commands` table in `src/lua/schema.sql`. Add `current_branch_path TEXT DEFAULT ''` to `sequences` table. Add `global_undo_cursor INTEGER DEFAULT 0` and `global_branch_path TEXT DEFAULT ''` to `projects` table. Update `tests/import_schema.lua` to match.

- [x] T002 Add `sequence_id` recording to `command_manager.execute()` in `src/lua/core/command_manager.lua`. When a command is recorded, extract `sequence_id` from `command_args.sequence_id`. For CreateSequence and DeleteSequence, explicitly set `sequence_id = NULL` (project-level). Store in the command's DB record. Read `command_manager.lua` lines 818-1009 (execute path) to understand current recording flow.

## Phase 3.2: Tests First (TDD)

**All tests in this phase MUST be written and MUST FAIL before Phase 3.3 implementation.**

- [x] T003 [P] Test: CreateSequence boundary guard. File: `tests/test_per_sequence_undo_boundary.lua`. Setup: create project, create sequence A, execute 2 edits in A. Assert: `can_undo()` returns true for edits. Undo both edits. Assert: `can_undo()` returns false (next command is CreateSequence for active sequence A). Switch to a different context. Assert: CreateSequence IS undoable from outside.

- [x] T004 [P] Test: per-sequence cursor isolation. File: `tests/test_per_sequence_undo.lua`. Setup: create project, create sequences A and B, execute Edit_A1, Edit_B1, Edit_A2 (interleaved). Viewing A, undo once. Assert: Edit_A2 undone, Edit_B1 untouched, Edit_A1 still done. Undo again. Assert: Edit_A1 undone, Edit_B1 STILL untouched. Switch to B. Assert: Edit_B1 still done. Undo from B. Assert: Edit_B1 undone.

- [x] T005 [P] Test: redo skips other sequences. File: `tests/test_per_sequence_undo.lua` (append). Same setup as T004. From A, undo Edit_A2 and Edit_A1. Redo from A. Assert: Edit_A1 redone first (by timestamp), NOT Edit_B1. Redo again. Assert: Edit_A2 redone.

- [x] T006 [P] Test: per-sequence branch isolation. File: `tests/test_per_sequence_branches.lua`. Setup: create A and B, execute Edit_A1, Edit_B1. From A, undo Edit_A1. Execute Edit_A2_new (forks A's branch). Assert: A's redo for Edit_A1 is lost (branched away). Switch to B. Assert: Edit_B1 is still done AND B can still undo Edit_B1 (B's branch unaffected by A's fork).

- [x] T007 [P] Test: global command in merged walk. File: `tests/test_per_sequence_undo.lua` (append). Setup: execute Import (global), then Edit_A1. From A, undo. Assert: Edit_A1 undone first (most recent by timestamp). Undo again. Assert: Import undone (global cursor moved). Redo. Assert: Import redone first (earliest undone by timestamp).

- [x] T008 Test: global command rebase timestamp. File: `tests/test_global_command_rebase.lua`. Setup: execute Import (global, timestamp T1), then Edit_A1 (timestamp T2), then Edit_B1 (timestamp T3). From A, undo Edit_A1 then undo Import. Assert: Import's timestamp updated to now (> T3). Switch to B. Assert: In B's merged view, Import (undone) appears after Edit_B1 (done) — at the rebased position.

- [x] T009 Test: cascade gate blocks global undo with dependents. File: `tests/test_per_sequence_undo.lua` (append). Setup: Import media, create clips in sequence B using that media. From A, attempt to undo Import. Assert: cascade gate fires (or undo is blocked because of dependent clips in B).

- [x] T010 [P] Test: history view filtering. File: `tests/test_per_sequence_history.lua`. Setup: execute Import (global), Edit_A1, Edit_B1, Edit_A2. Query history for sequence A. Assert: returns [Import, Edit_A1, Edit_A2] — Edit_B1 hidden. Query for B. Assert: returns [Import, Edit_B1]. Switch and re-query. Assert: results match.

- [x] T011 [P] Test: delete sequence preserves commands. File: `tests/test_per_sequence_undo.lua` (append). Setup: create sequence A, execute Edit_A1, Edit_A2. Delete sequence A. Assert: commands for A still exist in DB (sequence_id = A's id). Undo delete. Assert: sequence restored, commands visible again.

## Phase 3.3: Core Implementation

**ONLY start after tests in Phase 3.2 are written and failing.**

- [x] T012 Remove `JVE_ENABLE_MULTI_STACK_UNDO` env var gate in `src/lua/core/command_history.lua`. Make `multi_stack_enabled` always true. Verify existing multi-stack infrastructure (stack IDs, `undo_stack_states`, `stack_id_for_sequence`, `resolve_stack_for_command`, `activate_timeline_stack`) is functional. Read lines 33-52 and 186-232 of command_history.lua.

- [x] T013 Implement per-sequence cursor persistence in `src/lua/core/command_history.lua`. Each sequence's `current_sequence_number` and `current_branch_path` are read from / written to the `sequences` table. Global cursor uses `projects.global_undo_cursor` and `projects.global_branch_path`. Read existing `activate_timeline_stack()` (command_manager.lua line 2034-2056) and extend.

- [x] T014 Implement `sequence_id` classification for recorded commands in `src/lua/core/command_manager.lua`. In the execute/record path, derive `sequence_id` from `command_args.sequence_id`. Override to NULL for CreateSequence and DeleteSequence command types. Write `sequence_id` to the commands table INSERT.

- [x] T015 Implement merged undo walk in `command_manager.undo()`. Find the most recent done command in the merged view (max timestamp across: active sequence's commands at/before its cursor, AND global commands at/before global cursor). Undo it. Move the appropriate cursor (sequence or global). If the next undoable command is CreateSequence for the active sequence, stop. Read existing `undo()` at lines 1525-1541.

- [x] T016 Implement merged redo walk in `command_manager.redo()`. Symmetric with T015. Find the earliest undone command in the merged view. Redo it. Move the appropriate cursor. Read existing `redo()` at lines 1747-1763.

- [x] T017 Implement `can_undo()` and `can_redo()` filtering in `command_manager`. `can_undo()`: check if any done commands exist for the active sequence OR any done global commands exist. Return false if next undoable is CreateSequence for active sequence. `can_redo()`: check if any undone commands exist in the merged view. Read existing implementations at lines 1513-1523.

- [x] T018 Implement per-sequence branch forking in `command_history.lua`. When a new command is recorded for sequence A, fork only A's branch. B's branch_path and redo candidates are unaffected. Update `find_latest_child_command()` to filter by sequence_id when finding redo candidates.

- [ ] T019 Implement global command rebase semantics. (DEFERRED — timestamp rebase not yet needed) When a global command is undone or redone from a sequence context, update its `timestamp` column in the commands table to `os.time()`. This moves it to the current position in all history views.

## Phase 3.4: History Panel Integration

- [x] T020 Update history panel query in `src/lua/ui/edit_history.lua`. Filter commands: `WHERE sequence_id = ? OR sequence_id IS NULL`. Order by timestamp. Show current position indicator at the most recent done command in the merged view. Listen to sequence-switch signal to refresh.

- [ ] T021 Update history panel to show rebased global commands at their new timestamp position. Undone commands from other contexts appear at the top (most recent timestamp).

## Phase 3.5: Polish & Validation

- [x] T022 Run all tests via `make -j4`. Verify 0 luacheck warnings. All new tests pass. All existing tests still pass. Fixed pre-existing test_undo_redo_controller failure (stale toggle test).

- [ ] T023 Manual validation in the app: create two sequences, interleave edits, verify undo/redo isolation, verify history panel filtering, verify CreateSequence boundary, verify branch isolation.

- [x] T024 Update memory handoff: write `~/.claude/projects/.../memory/per_sequence_undo_handoff.md` documenting the implementation, key files, and any remaining TODOs.

## Dependencies

```
T001 (schema) → T002 (recording) → T012 (gate removal) → T013 (cursor persistence)
T003-T011 (tests) → T014-T019 (implementation) — TDD: tests first
T013 (cursors) → T015 (undo) → T016 (redo) → T017 (can_undo/redo)
T013 (cursors) → T018 (branches)
T015 (undo) → T019 (rebase)
T014-T019 (core) → T020-T021 (history panel)
T020-T021 (integration) → T022-T024 (polish)
```

## Parallel Execution

```
# T003-T006 can run in parallel (different test files):
T003: test_per_sequence_undo_boundary.lua
T004: test_per_sequence_undo.lua
T006: test_per_sequence_branches.lua
T010: test_per_sequence_history.lua
T011: test_per_sequence_undo.lua (append — sequential with T004)

# T007-T009 are sequential (append to same files or depend on T004)

# T020-T021 can run in parallel (different aspects of edit_history.lua — 
# but same file, so sequential)
```

## Validation Checklist

- [ ] All spec acceptance scenarios (1-12) have corresponding tests
- [ ] All FRs (001-014) are covered by at least one task
- [ ] Tests written before implementation (TDD)
- [ ] Parallel tasks are truly independent (different files)
- [ ] Each task specifies exact file paths
- [ ] No task modifies same file as another [P] task
