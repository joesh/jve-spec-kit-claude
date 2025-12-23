# 01-REPO-OVERVIEW

## Identity
JVE (Joe's Video Editor) - frame-accurate non-linear video editor combining Final Cut Pro 7's magnetic timeline with DaVinci Resolve's panel architecture.

## Technology Stack
- **Language**: C++ (Qt6 bindings) + Lua/LuaJIT (application layer)
- **UI**: Qt6 Widgets with full Lua scripting layer (`src/qt_bindings.cpp`)
- **Persistence**: SQLite with WAL mode (`src/lua/schema.sql`)
- **Build**: CMake (referenced in bug reporter)
- **Time System**: Rational arithmetic (`src/lua/core/rational.lua`) - frames at fractional rates (24000/1001)

## Directory Structure
```
src/
├── main.cpp                 # Qt application bootstrap
├── simple_lua_engine.{cpp,h} # Lua VM lifecycle
├── qt_bindings.{cpp,h}      # Qt FFI layer (1300+ LOC)
├── timeline_renderer.{cpp,h} # Native timeline rendering
├── bug_reporter/            # Integrated test capture system
└── lua/
    ├── schema.sql           # Database schema v5.0
    ├── core/                # Business logic (21k+ LOC)
    │   ├── command_*.lua    # Event sourcing system
    │   ├── ripple/          # Batch ripple algorithm
    │   ├── rational.lua     # Timebase math
    │   └── database.lua     # SQLite wrapper
    ├── models/              # Data layer
    ├── ui/                  # View layer
    │   ├── timeline/        # Timeline UI
    │   ├── project_browser.lua
    │   └── layout.lua       # Main window
    ├── importers/           # FCP7 XML, DRP, Resolve DB
    └── bug_reporter/        # Test harness

tests/                       # 200+ test files
docs/                        # Architecture docs
```

## Core Subsystems

### Event Sourcing
All edits are commands persisted to SQLite (`commands` table). Undo/redo replay command history. Located in:
- `src/lua/core/command_manager.lua` (1474 LOC)
- `src/lua/core/command_history.lua` (342 LOC)
- `src/lua/core/commands/*.lua` (45 command types)

### Timebase System
No floating-point time. All durations are `{frames, fps_numerator, fps_denominator}`:
- `src/lua/core/rational.lua` (380 LOC)
- Database stores ticks in native timebase per clip/sequence
- Rescaling on timebase boundaries

### Ripple Algorithm
Batch operations on timeline edges with gap materialization:
- `src/lua/core/ripple/batch/pipeline.lua` (40 LOC orchestrator)
- `src/lua/core/ripple/batch/prepare.lua` (edge snapshot)
- `src/lua/core/ripple/batch/context.lua` (operation state)
- 60+ ripple-specific tests

### Timeline State
Modular state management with persistence:
- `src/lua/ui/timeline/state/timeline_core_state.lua`
- `src/lua/ui/timeline/state/clip_state.lua`
- `src/lua/ui/timeline/state/selection_state.lua`
- SQLite stores viewport/playhead/selection as JSON

### Bug Reporter
Gesture capture + replay system for reproducibility:
- `src/bug_reporter/gesture_logger.{cpp,h}` (C++ layer)
- `src/lua/bug_reporter/*.lua` (Lua orchestration)
- Generates JSON test cases + screen recordings
- Default output: `tests/captures/capture-<datestamp>-<id>/capture.json` with `screenshots/` subdir
- Database snapshot: `tests/captures/bug-<datestamp>.db` when `database.backup_to_file` is available
- Output directory override via `metadata.output_dir` on export

## Data Model (SQLite)

### Schema v5.0
```sql
projects          # Top-level container
├── media         # Source files (native timebase)
├── sequences     # Timelines (master clock)
│   ├── tracks    # VIDEO/AUDIO lanes
│   │   └── clips # Timeline instances
│   └── commands  # Event log (undo/redo)
└── tags          # Hierarchical organization
```

### Key Constraints
- `PRAGMA foreign_keys = ON` (cascade deletes)
- Video tracks: NO OVERLAP (trigger enforcement)
- Audio tracks: allow mix
- All times in rational frames

## FFI Layer (`qt_bindings.cpp`)
Exposes Qt6 to Lua via manual bindings:
- Widget creation (QWidget, QPushButton, QLineEdit, etc.)
- Layouts (QVBoxLayout, QHBoxLayout, QSplitter)
- Event handling (signals/slots)
- Custom rendering (timeline_renderer)
- File I/O (QFile, QDir)

Pattern: Lua calls FFI, FFI validates, Qt executes. No business logic in FFI.

## Testing Infrastructure
- **Unit tests**: `tests/*.lua` (200+ files)
- **Integration tests**: `tests/integration/*.lua`
- **Fixtures**: `tests/fixtures/media/*.mp4`, `tests/fixtures/resolve/*.xml`
- **Test harness**: `tests/test_env.lua` (SQLite in-memory)
- **Bug reporter**: Captures gestures for differential validation

## Import/Export
- **FCP7 XML**: `src/lua/importers/fcp7_xml_importer.lua`
- **Resolve .drp**: `src/lua/importers/drp_importer.lua`
- **Resolve DB**: `src/lua/importers/resolve_database_importer.lua`

## Key Characteristics
1. **Lua-first architecture**: C++ is FFI layer, logic lives in Lua
2. **Frame-accurate timebase**: No floating-point time math
3. **Event sourcing**: All edits are replayable commands
4. **SQLite as runtime state**: DB is authoritative, not just persistence
5. **Test-driven**: 200+ regression tests with captured gestures
6. **Fail-fast development**: Assertions for invariant violations (ENGINEERING.md §1.14)

## Entry Point Flow
```
main.cpp
  → SimpleLuaEngine::executeFile("ui/layout.lua")
    → layout.lua creates main window
      → panel_manager.lua initializes panels
        → timeline_panel.lua connects to database
          → command_manager.init(db, sequence_id)
            → Application ready
```

## Build Products
- `jve` executable (Qt6 + LuaJIT linked)
- Lua scripts loaded at runtime from `src/lua/`
- SQLite .jvp project files in `~/Documents/JVE Projects/`
