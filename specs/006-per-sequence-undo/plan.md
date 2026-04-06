# Implementation Plan: Per-Sequence Undo Stacks & History Filtering

**Branch**: `006-per-sequence-undo` | **Date**: 2026-04-05 | **Spec**: `specs/006-per-sequence-undo/spec.md`
**Input**: Feature specification from `/specs/006-per-sequence-undo/spec.md`

## Summary

Add `sequence_id` column to the `commands` table. Per-sequence undo cursors and branch tracking replace the single global cursor. Undo/redo walk a merged view (sequence + global commands) by timestamp. History panel filters by active sequence. Global commands use rebase semantics when undone/redone from a sequence context. Cascade gates validate cross-sequence dependencies.

## Technical Context

**Language/Version**: Lua (LuaJIT) + C++ (Qt6)
**Primary Dependencies**: command_manager.lua, command_history.lua, SQLite (schema.sql)
**Storage**: SQLite `.jvp` project files
**Testing**: LuaJIT test harness (`tests/test_harness.lua`), `make -j4`
**Target Platform**: macOS (Darwin)
**Project Type**: Single (desktop app)
**Constraints**: All coordinates are integers. Fail-fast asserts. No fallbacks. No backward compat (2.15 — existing DBs get reset, not migrated).

## Constitution Check

**I. Modular Architecture**: Feature modifies command_manager and command_history (existing modules). New per-sequence cursor logic is isolated in command_history. History panel filtering is a view concern.
**II. Command-Driven Interface**: Undo/Redo are existing commands. No new commands needed — behavioral changes to existing undo/redo.
**III. Test-First Development**: TDD mandatory. Tests for each FR before implementation.
**IV. Documentation-Driven Specifications**: Spec complete with 14 FRs and 9 clarifications.
**V. Template-Based Consistency**: Following spec-kit workflow.
**VI. Fail-Fast Assert Policy**: Asserts on missing sequence_id, invalid cursor state, missing sequence records.
**VII. No Fallbacks**: No `or 0` on cursor positions. No fallback sequence_id. Assert on missing data.
**VIII. No Backward Compatibility**: Per ENGINEERING.md 2.15 — existing DBs with commands lacking sequence_id will be reset, not migrated. FR-014 (migration) is dropped in favor of clean-break.

## Project Structure

### Documentation (this feature)
```
specs/006-per-sequence-undo/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/tasks command)
```

### Source Code (affected files)
```
src/lua/
├── core/
│   ├── command_manager.lua      # undo(), redo(), can_undo(), can_redo() — per-sequence filtering
│   ├── command_history.lua      # Per-sequence cursors, branch tracking, merged walk
│   └── commands/
│       ├── create_sequence.lua  # Save previous_active_sequence_id on execute
│       └── delete_sequence.lua  # Preserve commands (already does)
├── schema.sql                   # Add sequence_id column to commands table
└── ui/
    └── edit_history.lua         # History panel — filtered display

tests/
├── test_per_sequence_undo.lua           # FR-002/003/004/005: cursor isolation
├── test_per_sequence_undo_boundary.lua  # FR-006: CreateSequence boundary
├── test_per_sequence_history.lua        # FR-009/010: history filtering
├── test_per_sequence_branches.lua       # FR-002: independent branches
├── test_cross_sequence_undo.lua         # FR-012: atomic cross-sequence
└── test_global_command_rebase.lua       # FR-008: rebase semantics
```

**Structure Decision**: Single project. Changes are within existing `src/lua/core/` modules. No new modules — extensions to command_manager and command_history.

## Phase 0: Research

No external unknowns. All technologies are already in use. Key research is internal:

1. **command_history.lua current state**: Multi-stack infrastructure exists but is gated behind `JVE_ENABLE_MULTI_STACK_UNDO`. Stack IDs, per-sequence cursor persistence (`sequences.current_sequence_number`), `activate_timeline_stack()` all exist. Need to understand what's wired vs stubbed.

2. **Branch tracking model**: Current `parent_sequence_number` + `current_branch_path` in command_history. Need to understand how to make this per-sequence.

3. **History panel (edit_history.lua)**: How it currently queries and displays commands. What needs to change for filtered display.

4. **Command args sequence_id availability**: Which commands already have `sequence_id` in args vs which don't. Determines project-level classification.

**Output**: research.md documenting current state of each subsystem and what changes are needed.

## Phase 1: Design

### Data Model Changes

1. **commands table**: Add `sequence_id TEXT` column (NULL = project-level). Derived from `command_args.sequence_id` at recording time.

2. **sequences table**: Already has `current_sequence_number`. Need to add `current_branch_path TEXT` for per-sequence branch tracking.

3. **projects table** (or app-level): Need storage for the global cursor position and branch path. Currently the single cursor lives in `command_history.lua` module state.

### Command Interface Changes

No new commands. Behavioral changes to:

- `command_manager.undo()`: Walk merged view by timestamp. Move appropriate cursor (sequence or global).
- `command_manager.redo()`: Symmetric with undo.
- `command_manager.can_undo()`: Check sequence cursor + global cursor. Stop at CreateSequence boundary.
- `command_manager.can_redo()`: Check for redoable commands in merged view.
- `command_manager.execute()`: Record `sequence_id` on the command. Fork only the active sequence's branch.

### Key Design Decisions

- **Merged walk**: `undo()` finds the most recent done command in the merged view (max timestamp across sequence cursor and global cursor). Undoes it. Moves the appropriate cursor.
- **Rebase**: When a global command is undone/redone from a sequence context, its timestamp is updated to `os.time()` (wall-clock now). All views see it at its new position.
- **Branch isolation**: Each sequence has its own `branch_path`. New command in A forks A's branch only. B's branch and redo path are unaffected.
- **Cross-sequence tagging**: Commands table gets a `secondary_sequence_id` column (or a join table). Deferred until cross-sequence commands actually exist in the codebase.

### Test Scenarios (from spec acceptance scenarios)

1. Two sequences interleaved — history shows only active + global
2. Switch sequences — history swaps
3. Undo 3 sequence edits — stops at global boundary
4. CreateSequence boundary — can_undo returns false
5. Undo global from A, switch to B — global rebased to top
6. Cascade gate blocks undo of import with dependent clips
7. Interleaved undo skips other sequence
8. Redo replays by timestamp
9. Delete sequence preserves commands
10. Independent branches — new in A doesn't affect B's redo

**Output**: data-model.md with schema changes, command interface changes

## Phase 2: Task Planning Approach

**Task Generation Strategy**:
- Schema change first (add columns)
- Per-sequence cursor infrastructure (command_history changes)
- Tests before each behavioral change (TDD per ENGINEERING.md)
- Undo/redo filtering (command_manager changes)
- History panel filtering (UI changes)
- Rebase semantics last (most complex)

**Ordering Strategy**:
- TDD order: test → implementation for each FR
- Dependency order: schema → cursor → undo/redo → history → rebase
- CreateSequence boundary guard (the immediate crash fix) as first task

**Estimated Output**: 15-20 numbered tasks

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Per-sequence branch tracking | FR-002 requires independent redo per sequence | Single branch loses B's redo when A forks |
| Rebase timestamp semantics | FR-008 prevents confusing display ordering | Original-position display creates done/undone interleaving |

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete
- [x] Phase 1: Design complete
- [x] Phase 2: Task planning complete (approach described)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved
- [x] Complexity deviations documented

---
*Based on Constitution v2.0.0 - See `.specify/memory/constitution.md`*
