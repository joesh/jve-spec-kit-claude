# jve-spec-kit-claude Development Status

Last updated: 2025-10-02 (Tag-based Organization)

## Active Technologies
- C++ (Qt6) + Lua (LuaJIT) hybrid architecture
- C++ for performance-critical: rendering, timeline manipulation, complex diffs
- Lua for UI logic, layout, interaction, extensibility
- SQLite for persistence

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
- Inspector UI not connected to data (widgets don't load/save clip properties)
- No media import functionality
- Most keyboard shortcuts non-functional
- Play button doesn't work

## Previous False Claims (REMOVED)
The previous documentation contained extensive false "milestone" claims about completed features. All systems described as "complete" or "operational" were either broken, partially implemented, or non-functional. This violated ENGINEERING.md Rule 0.1 (Documentation Honesty).

## Recent Improvements (2025-10-02)

**Tag-Based Media Organization:**
- Implemented flexible tag system replacing rigid folder hierarchy
- Media items now support multiple tag namespaces: bin, project, status, location, person, type, mood
- Hierarchical tags with path structure (e.g., "Footage/Interviews")
- Backward-compatible: existing UI shows "bin" namespace as traditional folders
- Foundation for multi-view filtering (can show different tag namespaces)
- Bins now alphabetically sorted

**Implementation Details:**
- `database.lua`: Media items have `tags` array with namespace/tag_path structure
- `load_bins()` extracts bins from "bin" namespace tags dynamically
- `load_media_tags()` queries tags by namespace
- `get_tag_namespaces()` lists all available namespaces
- Project browser updated to use tag-based filtering

## Next Steps
1. Connect inspector UI to clip data (add data binding)
2. Remove C++ UI components that violate architecture
3. Fix test system build issues

## Commit History
- 2025-10-02: Implement tag-based media organization with multiple namespaces
- 2025-10-01: Fix inspector panel initialization timing - now creates content during correct execution phase
- 2025-10-01: Code review and documentation cleanup - removed false milestone claims

