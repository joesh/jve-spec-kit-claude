
# Implementation Plan: Find, Sift, Find & Replace, and Timeline Search

**Branch**: `003-find-sift-find` | **Date**: 2026-03-26 | **Spec**: `specs/003-find-sift-find/spec.md`
**Input**: Feature specification from `/specs/003-find-sift-find/spec.md`

## Summary
Add Find (select matches), Sift (hide non-matches with Expand/Narrow composition), Find & Replace (undoable batch metadata editing), Timeline Quick Find (playhead-navigating search), Timeline Index (floating sortable clip list), and Smart Bins (persistent dynamic filters) to JVE Editor. Built on a shared query engine that powers all search operations. All state persists across sessions per JVE's design principles.

## Technical Context
**Language/Version**: Lua (LuaJIT) + C++ (Qt6)
**Primary Dependencies**: Qt6 (dialogs, widgets), LuaJIT FFI, dkjson (JSON)
**Storage**: SQLite (.jvp project files) — new `smart_bins` table, sift state in `projects.settings` JSON
**Testing**: LuaJIT test harness (`tests/run_lua_tests_all.sh`), `--test` mode for integration tests
**Target Platform**: macOS (Darwin)
**Project Type**: Single desktop application (Lua + C++ hybrid)
**Performance Goals**: Query engine must return results for 1000+ clips in <100ms (interactive feel)
**Constraints**: No schema migration system yet (Smart Bins table created via `CREATE TABLE IF NOT EXISTS`)
**Scale/Scope**: Projects with 100-5000 master clips, timelines with 50-500 clips

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**I. Library-First Architecture**: ✅ Query engine is a standalone pure-function module (`query_engine.lua`) with no UI dependencies. Sift state management is a separate module. Smart Bin persistence is isolated in its own model.
**II. CLI Interface Standard**: ⚠️ DEVIATION — This is a desktop GUI application. Commands are exposed through `command_manager` (the app's equivalent of CLI dispatch) rather than stdin/stdout. All operations are registered commands with keyboard shortcuts and menu items.
**III. Test-First Development**: ✅ TDD — query engine unit tests first, then command integration tests, then UI integration tests via `--test` mode.
**IV. Documentation-Driven Specifications**: ✅ Full spec with 30 acceptance scenarios, 7 clarifications resolved, 40+ functional requirements.
**V. Template-Based Consistency**: ✅ Commands follow existing registration pattern (SPEC + executor + undoer). Dialogs follow existing Qt dialog pattern (global handler callbacks).

## Project Structure

### Documentation (this feature)
```
specs/003-find-sift-find/
├── plan.md              # This file
├── research.md          # Phase 0: NLE research + technical decisions
├── data-model.md        # Phase 1: entities, schema, field registry
├── quickstart.md        # Phase 1: validation scenarios
├── contracts/
│   └── commands.md      # Phase 1: command specs (desktop app equivalent of API contracts)
└── tasks.md             # Phase 2 output (/tasks command)
```

### Source Code (new files for this feature)
```
src/lua/
├── core/
│   ├── query_engine.lua           # Shared query engine (pure functions, no dependencies)
│   ├── sift_state.lua             # Sift criteria management + persistence
│   ├── commands/
│   │   ├── find_clips.lua         # FindClips + FindNext commands
│   │   ├── sift.lua               # Sift + ExpandSift + NarrowSift + ClearSift
│   │   ├── replace_clip_property.lua  # ReplaceClipProperty + ReplaceAllClipProperties
│   │   └── smart_bin_commands.lua # CreateSmartBin + UpdateSmartBin + DeleteSmartBin
│   └── smart_bin.lua              # Smart Bin model (DB CRUD)
├── ui/
│   ├── find_dialog.lua            # Find dialog (shared by browser + timeline)
│   ├── find_replace_dialog.lua    # Find & Replace dialog
│   ├── sift_dialog.lua            # Sift dialog with Expand/Narrow/Clear buttons
│   ├── smart_bin_dialog.lua       # Smart Bin create/edit dialog
│   ├── timeline_index.lua         # Timeline Index floating dialog
│   └── project_browser/
│       └── sift_indicator.lua     # "(Sifted)" header indicator logic

tests/
├── test_query_engine.lua          # Unit tests for query matching
├── test_sift_state.lua            # Sift composition + persistence tests
├── test_find_commands.lua         # Find/FindNext command tests
├── test_sift_commands.lua         # Sift/Expand/Narrow/Clear command tests
├── test_replace_commands.lua      # Replace + ReplaceAll + undo tests
├── test_smart_bin.lua             # Smart Bin CRUD + dynamic update tests
└── test_timeline_find.lua         # Timeline find + index tests

keymaps/
└── default.jvekeys                # New keybinding entries (Cmd+F, Cmd+H, Cmd+G, etc.)
```

**Structure Decision**: Single desktop application. All new Lua modules follow existing directory conventions: `core/` for logic, `core/commands/` for command registrations, `ui/` for dialogs, `tests/` for test files.

## Phase 0: Research — Complete
All technical unknowns resolved. See `research.md` for decisions on:
- Compositional sift (Expand/Narrow) over boolean query builder
- Sift persistence in `projects.settings` JSON
- Smart Bins via new `smart_bins` table (`CREATE TABLE IF NOT EXISTS`, no migration needed)
- Keyboard shortcut conflict resolved: GoToTimecode moved to Ctrl+G, Cmd+G freed for Find Next
- Floating dialog for Timeline Index (migrates to dockable panel later)

## Phase 1: Design — Complete
Artifacts generated:
- `data-model.md`: Query, Sift State, Smart Bin, Find State, Replace Operation entities with field definitions, persistence strategy, state transitions, and searchable fields registry
- `contracts/commands.md`: 10 command specs (FindClips, FindNext, Sift, ExpandSift, NarrowSift, ClearSift, ReplaceClipProperty, ReplaceAllClipProperties, CreateSmartBin, UpdateSmartBin, DeleteSmartBin) with SPEC definitions, side effects, undo behavior
- `quickstart.md`: 35 validation test scenarios across 7 categories

## Phase 2: Task Planning Approach
*This section describes what the /tasks command will do — DO NOT execute during /plan*

**Task Generation Strategy**:
- Foundation layer first: query engine (pure functions, extensively tested)
- Then persistence: sift state module, smart bin model
- Then commands: one command file per feature area
- Then UI: dialogs, browser integration, timeline integration
- Then wiring: keybindings, menu items, signals
- Each layer has tests written BEFORE implementation (TDD)

**Ordering Strategy**:
- TDD order: test file → implementation → verify tests pass
- Dependency order: query_engine → sift_state/smart_bin → commands → dialogs → integration
- Mark [P] for parallel tasks within same layer (e.g., find_dialog and sift_dialog are independent)
- Mark [S] for sequential dependencies (commands depend on query_engine)

**Estimated Output**: 20-25 numbered, ordered tasks in tasks.md

**Key dependency chain**:
```
query_engine.lua [P]
├── sift_state.lua [S]
├── smart_bin.lua [S]
├── find_clips.lua [S]
├── sift.lua [S]
├── replace_clip_property.lua [S]
└── smart_bin_commands.lua [S]
    ├── find_dialog.lua [P]
    ├── sift_dialog.lua [P]
    ├── find_replace_dialog.lua [P]
    ├── smart_bin_dialog.lua [P]
    └── timeline_index.lua [P]
        └── keybindings + menus + browser integration [S]
```

## Complexity Tracking

| Deviation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| CLI Interface Standard (II) | Desktop GUI app — commands exposed via command_manager, not stdin/stdout | stdin/stdout is irrelevant for desktop NLE; command_manager IS the dispatch interface |
| No schema migration for smart_bins | Migration system is TODO/stub | `CREATE TABLE IF NOT EXISTS` is safe for additive tables; formalized when migration system ships |

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (/plan command)
- [x] Phase 1: Design complete (/plan command)
- [x] Phase 2: Task planning complete (/plan command - describe approach only)
- [x] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS (with documented CLI deviation)
- [x] Post-Design Constitution Check: PASS (query engine is library-first, TDD planned, all artifacts generated)
- [x] All NEEDS CLARIFICATION resolved
- [x] Complexity deviations documented

---
*Based on Constitution v1.0.0 - See `.specify/memory/constitution.md`*
