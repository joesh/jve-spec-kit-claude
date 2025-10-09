# jve-spec-kit-claude Development Status

Last updated: 2025-10-09 (Tree-Based Undo/Redo)

## Active Technologies
- C++ (Qt6) + Lua (LuaJIT) hybrid architecture
- C++ for performance-critical: rendering, timeline manipulation, complex diffs
- Lua for UI logic, layout, interaction, extensibility
- SQLite for persistence

READ ENGINEERING.md

## Project Structure
```
src/
  core/
    commands/        - Command system backbone (C++)
    models/          - Data models (C++)
    persistence/     - Database and migrations (C++)
    api/             - REST API managers (C++)
    timeline/        - Timeline management (C++)
  lua/
    ui/              - UI components (Lua) - PARTIALLY BROKEN
    core/            - Lua core modules
  ui/               - C++ UI components (VIOLATES ARCHITECTURE - should be Lua)
  main.cpp          - Application entry point
bin/
  JVEEditor         - Executable (builds, basic functionality)
tests/
  contract/         - Test source files exist but NO EXECUTABLES BUILD
```

## Commands
```bash
# Build system
make                 # Builds with warnings, LuaJIT linking issues
make clean          # Clean build artifacts

# Run the application  
./bin/JVEEditor      # Launches, shows 3-panel layout, timeline panel

# Testing - COMPLETELY BROKEN
# All test executables missing - none of these work:
# ./bin/test_* (21 tests defined but 0 executables exist)
```

## Architecture Status
**CORRECT (C++ for performance):**
- Core timeline operations
- Data models and persistence  
- Command system backbone
- Rendering systems

**INCORRECT (C++ should be Lua):**
- UI components in src/ui/ 
- Layout management
- User interaction logic
- Inspector panels

**BROKEN:**
- Test system - no executables build

**FIXED:**
- Inspector panel (Lua) - now initializes and creates content properly
- Inspector initialization timing - moved to correct execution phase
- Clip split functionality - UUID generation now properly seeded
- Widget type-based property getters in inspector
- Debug output spam eliminated from Qt bindings layer
- Tree-based undo/redo - follows parent links instead of linear sequence
- Selection preservation across undo/redo operations

## Current Issues (VERIFIED 2025-10-01)

**ARCHITECTURE VIOLATIONS:**
- UI components implemented in C++ (src/ui/) when they should be Lua
- Duplicate implementations: both C++ and Lua UI systems exist
- Inspector panel Lua implementation fails to initialize properly

**BUILD SYSTEM:**
- LuaJIT linking failure for test_scriptable_timeline  
- Multiple compiler warnings (unused lambda captures, missing Q_OBJECT)
- Test system completely broken: 21 test sources exist but 0 executables build

**UI BUGS:**
- Inspector collapsible sections show as collapsed but display content anyway
- Poor spacing throughout UI components
- Timeline chrome positioning misaligned

**FUNCTIONAL GAPS:**
- No media import functionality
- Most keyboard shortcuts non-functional
- Play button doesn't work

## Previous False Claims (REMOVED)
The previous documentation contained extensive false "milestone" claims about completed features. All systems described as "complete" or "operational" were either broken, partially implemented, or non-functional. This violated ENGINEERING.md Rule 0.1 (Documentation Honesty).

## Recent Improvements

**2025-10-09: Tree-Based Undo/Redo with Selection Preservation**
- Implemented proper tree-based undo/redo navigation for branching command history
  - Undo now follows `parent_sequence_number` links instead of decrementing sequence numbers
  - Redo queries for children and picks most recent (highest sequence_number) when multiple branches exist
  - Fixes bug where undoing from a new branch replayed wrong commands (command_manager.lua:1475)
- Selection preservation across undo/redo operations
  - Added `saved_selection_on_undo` pattern: save selection when undo pressed, restore on redo
  - Selection is user state (actions between commands), not command state
  - Simplified replay logic to only restore playhead, not selection (command_manager.lua:1427)
- Test scenario verified: F9 → select clip → F9 → undo → redo now preserves selection correctly

**2025-10-05: Timeline Track Separation (WIP)**
- Implemented visual track type separation with partitioned rendering
  - Timeline now partitions tracks into `video_tracks` and `audio_tracks` arrays on initialization
  - Video tracks (V1, V2, V3) render with blue-tinted headers (#3a3a5a)
  - Audio tracks (A1, A2, A3) render with green-tinted headers (#3a4a3a)
  - Visual separator bar drawn between video and audio sections
- Removed fake Qt label overlay system from timeline_panel.lua
  - Previous approach created Qt widgets that obscured timeline canvas rendering
  - Now uses unified drawing system - timeline module handles all visual output
- Database track loading fixed with correct field naming
  - Changed `type` field to `track_type` in database.lua for consistency
- Known limitations:
  - Track headers currently drawn ON canvas (should be fixed Qt widgets outside scroll area)
  - Separator is visual only (should be real QSplitter widget)
  - No independent scrolling for video/audio areas (needs QScrollArea bindings)
  - Architecture needs QScrollArea + QSplitter for proper FCP7-style layout

**2025-10-05: Split/UUID/Debug Fixes**
- Fixed critical bug where clip split operations caused clips to disappear
  - Root cause: `math.random()` was never seeded, producing identical UUID sequences on each app start
  - Fix: Added `math.randomseed(os.time() + os.clock() * 1000000)` in `models/clip.lua`
  - Clips created via split now get truly unique IDs and no longer overwrite existing clips
- Fixed inspector widget type errors during split operations
  - Inspector was calling `GET_TEXT` on all widgets regardless of type (sliders, checkboxes, etc.)
  - Added type-based dispatch: `GET_CHECKED` for booleans, `GET_SLIDER_VALUE` for ranged numbers, etc.
  - Both `save_all_fields()` and `apply_multi_edit()` now handle all widget types correctly
- Eliminated debug output spam from Qt bindings layer
  - Commented out 52 qDebug() statements in `qt_bindings.cpp`
  - Startup output reduced from thousands of lines to ~40 lines of meaningful info
  - No performance overhead from string formatting for unused debug messages

**2025-10-02: Tag-Based Media Organization**
- Implemented flexible tag system replacing rigid folder hierarchy
- Media items now support multiple tag namespaces: bin, project, status, location, person, type, mood
- Hierarchical tags with path structure (e.g., "Footage/Interviews")
- Backward-compatible: existing UI shows "bin" namespace as traditional folders
- Foundation for multi-view filtering (can show different tag namespaces)
- Bins now alphabetically sorted

## Next Steps
1. Connect inspector UI to clip data (add data binding)
2. Remove C++ UI components that violate architecture
3. Fix test system build issues

## Commit History
- 2025-10-09: Implement tree-based undo/redo with selection preservation for branching command history
- 2025-10-05: Fix clip split disappearing bug, inspector widget type errors, and debug output spam
- 2025-10-02: Implement tag-based media organization with multiple namespaces
- 2025-10-01: Fix inspector panel initialization timing - now creates content during correct execution phase
- 2025-10-01: Code review and documentation cleanup - removed false milestone claims

