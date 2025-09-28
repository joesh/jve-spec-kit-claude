# jve-spec-kit-claude Development Guidelines

Auto-generated from all feature plans. Last updated: 2025-09-28

## Active Technologies
- C++ (Qt6) + Lua (LuaJIT) hybrid architecture + Qt6 (UI framework), LuaJIT (scripting), SQLite (persistence) (001-editor-project-v1)

## Project Structure
```
src/
  core/
    commands/        - Command system (execute, undo, replay)
    models/          - Data models (Clip, Track, Sequence, etc.)
    persistence/     - Database and migrations
    api/             - REST API managers
  ui/
    selection/       - Professional multi-selection system
tests/
  contract/          - API contract tests (88.9% passing)
```

## Commands
```bash
# Build system
make                 # Build all targets
make clean          # Clean build artifacts

# Testing
./bin/test_command_execute    # Timeline operations (PASSING)
./bin/test_command_undo       # Undo/redo system (PASSING) 
./bin/test_selection_system   # Multi-selection (PASSING)
```

## Code Style
C++ (Qt6) + Lua (LuaJIT) hybrid architecture: Follow standard conventions
- Qt6 coding conventions with qCDebug logging
- Professional video editing patterns (Avid/FCP7/Resolve)
- TDD methodology with contract-first testing

## Recent Changes
- 001-editor-project-v1: Added C++ (Qt6) + Lua (LuaJIT) hybrid architecture + Qt6 (UI framework), LuaJIT (scripting), SQLite (persistence)
- 2025-09-28: **MAJOR MILESTONE** - Command system implementation completed with 88.9% test success rate
  - ✅ Professional timeline operations (create_clip, delete_clip, split_clip, ripple_delete, ripple_trim, roll_edit)
  - ✅ Rich delta generation system with clips_created/deleted/modified arrays  
  - ✅ Error code consistency (INVALID_COMMAND, INVALID_ARGUMENTS)
  - ✅ Undo/redo system with proper inverse command generation
  - ✅ Multi-selection with tri-state controls and professional editor patterns
  - ⚡ Known limitation: deterministic replay (UUID generation variability)

<!-- MANUAL ADDITIONS START -->
<!-- MANUAL ADDITIONS END -->