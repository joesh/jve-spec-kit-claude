# jve-spec-kit-claude Development Status

Last updated: 2025-10-11 (Ripple Trim Constraint System)

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
- Undo position persistence across app sessions (command_manager.lua, schema.sql)
- Inspector notification on startup with restored selection (timeline_panel.lua)
- Direct clip modifications now blocked to enforce event sourcing (timeline_state.lua)
- Edge selection system with bracket indicators `[` `]` `][` for trimming operations
- Ripple trim constraint system - 9 critical bugs fixed for proper gap/overlap handling

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

**2025-10-10: FCP7 XML Import System**
- Implemented complete Final Cut Pro 7 (XMEML) import capability
  - Industry-standard interchange format for timeline migration
  - Parses sequences, tracks, clips, and media references
  - Handles rational time notation (900/30 frames) with frame-accurate conversion
  - Supports both NTSC (29.97fps) and integer frame rates
- FCP7 XML parser (fcp7_xml_importer.lua)
  - `parse_time()`: Converts FCP7 rational notation to milliseconds
  - `extract_frame_rate()`: Handles timebase with NTSC flag detection
  - `parse_file()`: Extracts media references with pathurl decoding
  - `parse_clipitem()`: Maps clip in/out points and timeline positions
  - `parse_track()`: Processes video/audio tracks with enabled/locked states
  - `parse_sequence()`: Complete sequence hierarchy parsing
- Data model mapping
  - FCP7 `<clipitem>` → JVE Clip with start_time, duration, source_in/out
  - FCP7 `<track>` → JVE Track with VIDEO/AUDIO type and index
  - FCP7 `<sequence>` → JVE Sequence with frame rate, dimensions
  - URL decoding: `file://localhost/path%20with%20spaces.mov` → `/path with spaces.mov`
- Command integration
  - **ImportFCP7XML** command with full undo/redo
  - Creates sequences, tracks, clips in database
  - Stores created entity IDs for rollback
  - Undo deletes all imported entities in correct order
- Format support
  - Root `<xmeml>` validation
  - Direct sequence import
  - Project container with nested sequences
  - Video and audio track separation
  - Clip enable/disable state preservation
- Files: src/lua/importers/fcp7_xml_importer.lua, src/lua/core/command_manager.lua

**2025-10-10: Premiere-Style Keyboard Customization Dialog**
- Implemented complete keyboard shortcut customization system matching Adobe Premiere Pro's design
  - Two-pane layout: searchable command tree (left) + shortcut editor (right)
  - Live search filtering with category expansion
  - Multiple shortcuts per command (professional feature)
  - Conflict detection with red warning labels
  - Preset management (save/load/share custom configurations)
- Keyboard shortcut registry (keyboard_shortcut_registry.lua)
  - Central command registry with categories, descriptions, default shortcuts
  - Platform-agnostic shortcut notation ("Cmd+Z" → Meta on Mac, Ctrl on Windows)
  - `register_command()`: Add commands to registry
  - `assign_shortcut()`: Map key combos to commands with conflict checking
  - `find_conflict()`: Detect duplicate assignments
  - `save/load_preset()`: Manage custom shortcut sets
  - `format_shortcut()`: Human-readable display (Cmd+Shift+Z)
- Pure Lua dialog implementation (keyboard_customization_dialog.lua) ✅ **ARCHITECTURE COMPLIANT**
  - Uses existing Qt bindings (CREATE_TREE, CREATE_BUTTON, CREATE_LAYOUT, etc.)
  - No C++ required - fully customizable by users without recompiling
  - Two-pane splitter layout with command tree and shortcuts panel
  - Live search filtering (when Qt binding available)
  - Command tree with category grouping and expansion
  - Shortcuts list showing all assigned shortcuts per command
  - Preset combo box with Default, Premiere Pro, Final Cut Pro presets
  - Add/Remove/Clear buttons for shortcut management
  - Apply/Cancel/OK buttons with unsaved changes tracking
- Features
  - Search commands in real-time (filters tree as you type)
  - Assign multiple shortcuts to one command
  - Remove/clear shortcuts individually or all at once
  - Save custom presets with names
  - Reset to defaults with confirmation
  - Platform-aware modifier display (Cmd on Mac, Ctrl on Windows/Linux)
- **Architectural win**: Refactored from C++ to pure Lua following project principles
  - Users can now customize dialog layout/behavior in `src/lua/ui/keyboard_customization_dialog.lua`
  - No recompilation needed for UI changes
  - Follows same pattern as timeline (C++ bindings + Lua UI)
- Files: src/lua/core/keyboard_shortcut_registry.lua, src/lua/ui/keyboard_customization_dialog.lua

**2025-10-10: Linked Clips and A/V Sync System**
- Implemented complete linked clip system for A/V synchronization
  - New `clip_links` table stores link group relationships
  - Link groups support multiple clips (1 video + N audio channels)
  - Role-based linking: VIDEO, AUDIO_LEFT, AUDIO_RIGHT, AUDIO_MONO, AUDIO_CUSTOM
  - Time offset support for dual-system sound workflows
  - Temporary enable/disable without breaking links
- Link management module (clip_links.lua)
  - `get_link_group()`: Find all clips in same link group
  - `create_link_group()`: Establish A/V sync relationships
  - `unlink_clip()`: Remove clip from group (auto-cleanup if ≤1 clips remain)
  - `enable/disable_link()`: Temporarily suspend link behavior
  - `calculate_anchor_time()`: Find reference point for maintaining sync
- Command system integration
  - **LinkClips** command: Create link groups with full undo/redo
  - **UnlinkClip** command: Break links with restoration support
  - **Nudge** command: Automatically moves linked clips together
    - Expands selection to include all clips in link groups
    - Shows count: "Nudged 1 clip(s) + 2 linked clip(s) by 33ms"
- Database schema updates
  - `clip_links` table with composite primary key (link_group_id, clip_id)
  - Indexed for fast group lookups and reverse lookups
  - Foreign key cascade delete maintains referential integrity
- Files: schema.sql, src/lua/core/clip_links.lua, src/lua/core/command_manager.lua

**2025-10-10: Timeline Constraints and Frame-Accurate Editing**
- Implemented comprehensive collision detection system (timeline_constraints.lua)
  - `calculate_trim_range()`: Determines min/max delta for edge trims based on adjacent clips, media boundaries, minimum duration
  - `calculate_move_range()`: Determines valid time range for clip moves
  - `clamp_trim_delta()`: Automatically constrains and snaps trim operations to valid range
  - `check_*_collision()`: Validates operations before execution
- Frame boundary enforcement (frame_utils.lua)
  - All video editing operations now snap to frame boundaries (33.33ms at 30fps)
  - `snap_to_frame()`: Rounds absolute times to nearest frame
  - `snap_delta_to_frame()`: Rounds relative changes to frame multiples
  - `format_timecode()` / `parse_timecode()`: Professional timecode string handling
  - `validate_clip_alignment()`: Checks clip parameters are frame-aligned
- Constraint types enforced:
  - ✅ Adjacent clips: Cannot trim/move into another clip
  - ✅ Minimum duration: Clips must be ≥1ms
  - ✅ Timeline boundaries: Clips cannot start before t=0
  - ✅ Media boundaries: Cannot trim beyond source_in=0
  - ✅ Frame alignment: All operations snap to frame boundaries
- RippleEdit command now clamps and snaps delta before execution
- Insert command snaps all parameters (insert_time, duration, source_in/out) to frames
- Warning messages indicate reason for adjustment (collision vs frame snap)
- Files: src/lua/core/timeline_constraints.lua, src/lua/core/frame_utils.lua, src/lua/core/command_manager.lua

**2025-10-11: Ripple Trim Constraint System - Complete Fix**
- Fixed 9 critical bugs in ripple edit constraint calculation (RippleEdit executor in command_manager.lua)

**Bug 1: Gap Ripple Point Calculation**
  - Problem: Gap_before used left edge instead of right edge for ripple point
  - Impact: All clips marked as "shifting" with no stationary clips → infinite constraints
  - Fix: gap_after uses clip.start_time (left edge), gap_before uses clip.start_time + clip.duration (right edge)

**Bug 2: Stationary Clip Detection**
  - Problem: Used `c.start_time + c.duration <= ripple_time` instead of checking where clip starts
  - Impact: Clips extending past ripple point weren't considered stationary
  - Fix: Changed to `c.start_time < ripple_time` - clips are stationary if they start before ripple point

**Bug 3: Cross-Track Collision Detection**
  - Problem: Constraint check was `other.track_id == clip.track_id`, but ripple affects ALL tracks
  - Impact: Clips on different tracks allowed to overlap during ripple operations
  - Fix: Added `check_all_tracks` parameter to timeline_constraints.lua, passed as `true` for ripple operations

**Bug 4: Overlapping Clip Constraints**
  - Problem: Normal constraint logic doesn't handle negative gaps (overlaps)
  - Impact: Contradictory constraints (min_shift = 567, max_shift = -567) when clips already overlapped
  - Fix: Added overlap handling - blocks LEFT shift (increases overlap), allows RIGHT shift (fixes overlap)

**Bug 5: Touching Clips Blocked Rightward Movement**
  - Problem: When clips touched (gap=0), constraint set max_shift = 0, preventing separation
  - Impact: Couldn't create space between touching clips
  - Fix: Removed max_shift constraint from stationary clips - only min_shift (leftward) is constrained

**Bug 6: Command Return Value Type Mismatch**
  - Problem: Error cases returned `false` instead of `{success = false, error_message = "..."}`
  - Impact: Drag operation failed entirely, rubber band disappeared instead of constraining to limit
  - Fix: Changed all 6 error returns (lines 1913, 1927, 1982, 2121, 2188, 2204) to return proper result tables

**Bug 7: Coordinate Space Mismatch (Shift vs Delta)**
  - Problem: Constraint code calculated limits in shift space but applied them in delta space
  - Impact: For in-point edits where shift = -delta, constraints didn't limit drag correctly
  - Fix: Added conversion logic - for in-point, flip signs (min_shift → max_delta, max_shift → min_delta)

**Bug 8: Frame Snapping Exceeded Constraints**
  - Problem: Clamp to 1366ms, then snap to 1367ms, exceeding constraint limit
  - Impact: Operation failed because snapped value created invalid clip duration
  - Fix: Added re-clamping after snapping to ensure frame-snapped value doesn't exceed constraints

**Bug 9: Missing Gap Duration Constraint**
  - Problem: Gap constraint checked collisions but not gap's own minimum duration (must be ≥1ms)
  - Impact: A 1366ms gap allowed delta=1366ms which would make duration=0ms (invalid)
  - Fix: Added `max_closure_shift = -(clip.duration - 1)` constraint before delta conversion

**Technical Concepts Implemented:**
  - Gap Materialization: Virtual "gap clip" objects for constraint calculations on empty timeline spaces
  - Deterministic Replay: Clamped_delta_ms and gap boundaries stored for exact replay
  - Multi-Track Ripple: All downstream clips shift together across all tracks
  - Coordinate Space Conversion: Shift space (clip movement) ↔ Delta space (edge drag amount)
  - Constraint Composition: Adjacent clips, duration limits, media boundaries, timeline boundaries

**Files Modified:**
  - src/lua/core/command_manager.lua (RippleEdit executor with 9 constraint fixes)
  - src/lua/core/timeline_constraints.lua (added check_all_tracks parameter)
  - src/lua/ui/timeline/timeline_view.lua (improved error logging)

**2025-10-09: Professional Edge Selection for NLE Trimming**
- Implemented complete edge selection system following FCP7/Premiere/Resolve patterns
  - Bracket-style visual indicators: `[` for in-points, `]` for out-points, `][` for edit points
  - Color-coded availability: green (#66ff66) for trimmable edges, red (#ff6666) for media limits
  - 8px tolerance zone for precise edge detection
- Edit point semantics: `][` represents selecting the boundary between adjacent clips
  - Out-point of left clip `]` + in-point of right clip `[` selected simultaneously
  - Enables roll edits (moving edit point without changing total duration)
- Single edge selection: Click within 8px of isolated edge selects `[` or `]` only
  - Enables ripple edits (trim edge with downstream timeline shift)
- Cmd-click multi-select for asymmetrical trimming across multiple clips
- Two-pass detection algorithm: find all edges near click, select all detected
- Foundation complete for implementing actual trim commands (roll/ripple edits)
- Files: src/lua/ui/timeline/timeline_state.lua, src/lua/ui/timeline/timeline_view.lua

**2025-10-09: Session State Persistence & Event Sourcing Enforcement**
- Undo position now persists across app sessions
  - Added `current_sequence_number` field to sequences table (schema.sql)
  - command_manager.lua init() loads saved undo position from database
  - save_undo_position() called after execute, undo, redo operations
  - Fixes bug where redo didn't work after restarting app from undone state
- Inspector now notified of restored selection on startup
  - timeline_panel.set_inspector() checks for existing selection and notifies immediately
  - Handles initialization order issue where selection restored before inspector wired up
  - Inspector now displays selected clip properties immediately on app restart
- Direct clip modifications now blocked to enforce event sourcing discipline
  - timeline_state.update_clip() now throws error instead of modifying state
  - Prevents "phantom changes" that exist in database but not in event log
  - All state modifications must go through command_manager for proper undo/redo
  - Clear error message guides developers to use command system instead

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
- 2025-10-11: Fix 9 critical ripple trim constraint bugs - gap calculation, cross-track collisions, overlap handling
- 2025-10-09: Implement professional edge selection system for NLE trimming operations
- 2025-10-09: Persist undo position across sessions and enforce event sourcing discipline
- 2025-10-09: Implement tree-based undo/redo with selection preservation for branching command history
- 2025-10-05: Fix clip split disappearing bug, inspector widget type errors, and debug output spam
- 2025-10-02: Implement tag-based media organization with multiple namespaces
- 2025-10-01: Fix inspector panel initialization timing - now creates content during correct execution phase
- 2025-10-01: Code review and documentation cleanup - removed false milestone claims

