# Implementation Plan: No Active Sequence State

**Branch**: `010-first-class-no` | **Date**: 2026-04-16 | **Spec**: [spec.md](./spec.md)
**Input**: `/Users/joe/Local/jve-spec-kit-claude/specs/010-first-class-no/spec.md`

## Execution Flow (/plan command scope)
```
1. Load feature spec from Input path           ✅
2. Fill Technical Context                       ✅ (no NEEDS CLARIFICATION)
3. Fill Constitution Check                      ✅
4. Evaluate Constitution Check                  ✅ (no violations)
5. Execute Phase 0 → research.md                ✅
6. Execute Phase 1 → contracts, data-model, quickstart  ✅
7. Re-evaluate Constitution Check               ✅
8. Plan Phase 2 (describe /tasks approach)      ✅
9. STOP — ready for /tasks
```

## Summary
Make "no active sequence" a first-class editor state. Three triggers enter it: close-last-tab, open-project-without-tab-info, sequence-deletion (active or non-active tab's backing sequence removed). Drop-to-blank-timeline creates one new sequence (fps/resolution from first clip; name `<first-clip> (+N more)`) and/or opens dropped sequences as tabs. Commands/shortcuts grey out while blank; undo falls through to a project-level stack. DRP importer resolver asserts on malformed TimelineHandleVec (cases 2/3/4); legitimately leaves empty when no tab metadata exists at all (case 1).

Technical approach: introduce `clear()` primitives on `timeline_state` and `command_manager`; add `timeline_panel.unload_sequence()` inverse of `load_sequence`; remove `find_most_recent` / `sequences[1]` fallbacks from the project-open path; rewire `close_tab`'s last-tab case + sequence-delete cascades; replace DRP resolver's `log.warn` fallthrough with asserts. No SQL schema change; `open_sequence_ids` already JSON — blank persists as `[]`; `last_open_sequence_id` persists as `""` or unset.

## Technical Context
**Language/Version**: Lua (LuaJIT 2.1) + C++17 (Qt 6.6)
**Primary Dependencies**: Qt6 (widgets, signals), SQLite via existing `core.database`, existing modules: `command_manager`, `timeline_state`, `timeline_panel`, `selection_hub`, `sequence_monitor`
**Storage**: SQLite `.jvp` project files. **No schema change.** Uses existing `project_settings` rows for `open_sequence_ids` (JSON) and `last_open_sequence_id` (TEXT).
**Testing**: LuaJIT test harness (`tests/*.lua` via `tests/run_lua_tests_all.sh`) + `--test` mode binding tests (`tests/binding/*.lua` run inside `./build/bin/JVEEditor`). Luacheck gate.
**Target Platform**: macOS (primary), Qt-supported desktops
**Project Type**: Single (one Lua/C++ codebase)
**Performance Goals**: Blank-state transitions instant (<100 ms perceived); no new hot loops.
**Constraints**:
- No new DB schema
- Must not regress existing DRP tab-restore tests (`test_drp_active_timeline_restored.lua` + `test_drp_open_timelines.lua` + `test_drp_anamnesis_full.lua`)
- Must not regress existing 508 pure-Lua tests
- Drop-to-new-sequence reuses existing `new_sequence` + `insert_clip` command paths (no new command types)
**Scale/Scope**: ~10 Lua files modified, ~5 new/expanded functions, 1 new binding test, 3–4 new pure-Lua tests. Estimated 300–500 LOC delta.

## Constitution Check
*(mapped to JVE Constitution v2.0.0 principles)*

| Principle | Check | Status |
|---|---|---|
| I. Modular Architecture (MVC, pull-not-push) | Blank state = view pulls "no active seq" from model via `get_sequence_id() == nil`. No push of empty content. | ✅ |
| II. Command-Driven Interface | No new command types introduced; existing `new_sequence` + `insert_clip` reused for drop-to-new. Disabled-shortcut behavior uses existing command gating (`can_execute`). | ✅ |
| III. Test-First Development | Regression tests written first (one per acceptance scenario + one for each DRP resolver failure case). Verified red before implementing. | ✅ planned |
| IV. Documentation-Driven Specs | spec.md + plan.md + data-model.md + contracts/ + quickstart.md present before implementation. | ✅ |
| V. Template-Based Consistency | Uses `.specify` templates throughout. | ✅ |
| VI. Fail-Fast Assert Policy | DRP resolver cases 2/3/4 become asserts; `close_tab` no-op removed; startup fallbacks removed. Case 1 (DRPs with no tab metadata) is an explicit outcome, not a silent fallback. | ✅ |
| VII. No Fallbacks | Removes `find_most_recent` and `sequences[1]` silent fallbacks. `clear()`/`unload` persist the explicit empty state. No `or {}` defaults on required data. | ✅ |
| VIII. No Backward Compatibility | Legacy projects with missing `last_open_sequence_id` previously got auto-filled with sequences[1]; now they open blank. **User-visible behavior change** — acceptable per principle VIII. | ✅ |

No violations. Complexity Tracking table empty.

## Project Structure

### Documentation (this feature)
```
specs/010-first-class-no/
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
├── quickstart.md        ← Phase 1 output
├── contracts/
│   ├── timeline_state.md
│   ├── timeline_panel.md
│   ├── command_manager.md
│   └── drp_importer.md
└── tasks.md             ← /tasks output (NOT created here)
```

### Source Code (repository root)
Single-project Lua/C++ layout (already in place):
```
src/lua/
├── core/
│   ├── command_manager.lua            ← add: deactivate(); undo/redo routes to project stack when no active
│   └── commands/
│       ├── open_project.lua           ← remove find_most_recent fallback + assert
│       └── new_project.lua            ← same
├── ui/
│   ├── layout.lua                     ← remove sequences[1] fallback; honor nil last_open_sequence_id
│   └── timeline/
│       ├── timeline_panel.lua         ← add: unload_sequence(); rewire close_tab last-tab case; drop-to-blank handler
│       ├── state/
│       │   └── timeline_core_state.lua ← add: clear()
│       └── view/
│           └── timeline_view_drag_handler.lua ← nil-guard; delegate empty-state drop to timeline_panel
├── importers/
│   └── drp_importer.lua               ← resolve_project_tab_ids: cases 2/3/4 → assert
└── core/
    └── keyboard_shortcuts.lua         ← nil-guard active sequence before command dispatch
tests/
├── test_timeline_state_clear.lua                    ← NEW pure
├── test_unload_sequence_persists_empty.lua          ← NEW pure
├── test_drp_resolver_asserts_malformed.lua          ← NEW pure (pcall around fabricated inputs)
├── test_project_open_no_tab_info_stays_blank.lua    ← NEW pure
└── binding/
    └── test_close_last_tab_enters_blank.lua         ← NEW --test-mode
```

**Structure Decision**: Single-project. No new directories. All changes live in existing module files; new tests colocated with existing test layout.

## Phase 0: Research

See [research.md](./research.md). Key decisions:

- Introduce `clear()` on state + command_manager rather than overloading `init(nil,nil)`. Rationale: init has many positional assertions; a separate clear() keeps init's contract strict.
- Add `unload_sequence()` on timeline_panel as inverse of `load_sequence`: state.clear(), command_manager.deactivate(), blank timeline monitor, clear selection, persist `open_sequence_ids=[]` and `last_open_sequence_id=""`. Emits existing `selection_hub.update_selection("timeline", {})` so inspector auto-reacts (MVC pull).
- No new signal. `selection_hub` already re-broadcasts on selection change; monitors poll state per tick. A `sequence_unloaded` signal would duplicate existing flow.
- DRP resolver cases 2/3/4 assert; case 1 leaves empty. Matches principle VI.
- Drop-to-blank reuses existing commands (`create_sequence` + per-clip `insert_clip`), wrapped in one undo group. Sequence naming ("+N more") computed in the drop handler before `create_sequence`.
- Undo project-level fallback uses existing per-sequence + project-level stacks (command_manager already separates them); the routing picks project when no active sequence.

## Phase 1: Design & Contracts

### Data model
See [data-model.md](./data-model.md). No new SQL. Entity-level additions:
- `ActiveSequenceRef` is now explicitly nullable in-memory. `timeline_state.get_sequence_id()` returns `string | nil`.
- `ProjectTabState.open_ids` may be `[]`.
- `ProjectTabState.active_id` may be `""` or unset (treat as nil).

### API contracts
Split across `contracts/*.md`:
- [timeline_state.md](./contracts/timeline_state.md) — `clear()` added; `get_*` return nil when cleared.
- [timeline_panel.md](./contracts/timeline_panel.md) — `unload_sequence()` added; `close_tab` last-case rewired; `create(opts)` tolerates nil `sequence_id`; drop-to-blank handler.
- [command_manager.md](./contracts/command_manager.md) — `deactivate()` added; undo/redo routes to project stack when no active sequence.
- [drp_importer.md](./contracts/drp_importer.md) — `resolve_project_tab_ids` assert set documented.

### Contract tests (must fail on current code before implementation)
- `test_timeline_state_clear.lua` — asserts `get_sequence_id() == nil` after `state.clear()`. Current: function doesn't exist → errors → ✅ red.
- `test_unload_sequence_persists_empty.lua` — asserts `open_sequence_ids == {}` and `last_open_sequence_id == ""` after unload. Current: function doesn't exist → ✅ red.
- `test_drp_resolver_asserts_malformed.lua` — drives `resolve_project_tab_ids` with out-of-range CTI, missing `Sm2Sequence` mapping; asserts via `pcall` that each throws an actionable error. Current: uses `log.warn` + returns silently → ✅ red.
- `test_project_open_no_tab_info_stays_blank.lua` — writes a project with empty tab settings and no `last_open_sequence_id`, runs open flow; asserts `timeline_state.get_sequence_id() == nil` post-open. Current: falls back to `find_most_recent` → ✅ red.
- `test_close_last_tab_enters_blank.lua` (binding, `--test` mode) — open 1-seq project, close its tab, assert state + DB empty. Current: reopens the closed tab (TODO hack) → ✅ red.

### Quickstart
See [quickstart.md](./quickstart.md) — step-by-step manual validation against a fresh editor build.

### Agent context update
Skipped — this change is internal refactor; no new tech stack, no new pattern worth advertising in CLAUDE.md. The constitution already covers the fail-fast policy this change enforces.

## Post-Design Constitution Check

Re-evaluated after Phase 1. No violations introduced. Drop-to-new-sequence uses existing command types (principle II preserved). Tests-first plan intact (principle III). `state.clear()` + `unload_sequence()` are explicit positive state transitions, not silent fallbacks (principles VI + VII).

## Phase 2: Task Generation Approach

*Description only — /tasks creates tasks.md.*

**Strategy**:
1. Load `.specify/templates/tasks-template.md`.
2. One task per contract-test file (five tests above). All `[P]` parallel (separate files).
3. Implementation tasks grouped by layer:
   - State layer: `timeline_core_state.clear()`.
   - Command layer: `command_manager.deactivate()`; undo routing.
   - UI primitives: `timeline_panel.unload_sequence()`.
   - UI wiring: `close_tab` last-case, `create(nil)` tolerance, drag-to-blank handler.
   - Startup: `layout.lua` fallback removal, `open_project.lua` + `new_project.lua`.
   - Importer: `resolve_project_tab_ids` asserts.
   - Cross-cutting nil-guards: `drag_handler`, `keyboard_shortcuts`.
4. Validation: full `make -j4`, binding-test run, manual quickstart.
5. Commit checkpoints at each layer boundary.

**Ordering**:
- Contract tests first (red before any code).
- State → command → UI primitives → UI wiring → startup → importer → nil-guards → validation.
- Each layer ends with its own make-test gate.

**Estimated output**: 22–26 tasks.

## Progress Tracking

- [x] Phase 0 research complete
- [x] Phase 1 design complete (data-model, contracts, quickstart)
- [x] Constitution check passed (initial + post-design)
- [x] Phase 2 planning described (tasks.md NOT created)
- [ ] /tasks executed

## Complexity Tracking

No constitutional violations.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| — | — | — |
