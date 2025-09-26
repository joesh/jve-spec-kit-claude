# JVE Editor Source Code Structure

## Architecture Overview
This project implements a hackable, script-forward video editor using C++/Qt6 + Lua architecture.

## Directory Structure

### Core Engine (`src/core/`)
- **models/**: SQLite-backed entity classes (Project, Sequence, Clip, etc.)
- **commands/**: Deterministic command system for editing operations
- **persistence/**: SQLite integration, atomic saves, command logging

### User Interface (`src/ui/`)
- **panels/**: Main UI panels (Project Browser, Timeline, Inspector, Viewers)
- **widgets/**: Custom controls (tri-state inputs, timeline elements)
- **dialogs/**: Modal interactions and configurations
- **selection/**: Multi-selection system for clips and edges
- **timeline/**: Timeline-specific rendering and interaction
- **input/**: Keyboard shortcuts and input handling
- **theme/**: Professional dark theme implementation

### Lua Integration (`src/lua/`)
- **runtime/**: LuaJIT initialization and management
- **api/**: C++ to Lua bindings for command system access
- **scripts/**: Default panel behaviors and extensibility hooks

### Command Line Tools (`src/cli/`)
- Debugging and validation utilities (jve-validate, jve-dump, jve-replay)

## Testing Structure (`tests/`)
- **contract/**: API contract tests (TDD first)
- **integration/**: End-to-end workflow tests
- **unit/**: Individual component tests
- **lua/**: Script runtime and behavior tests

## Design Principles
- **Library-First**: Each component is a testable, standalone library
- **Script-Forward**: Lua for logic/policy, C++ for performance
- **Test-First**: All tests written before implementation (TDD)
- **Single-File Projects**: .jve files are self-contained with no sidecars