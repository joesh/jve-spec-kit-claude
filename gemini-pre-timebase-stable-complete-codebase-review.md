# JVE Codebase Review & Analysis

## Executive Summary

The JVE project is a sophisticated **non-linear editing (NLE) data management system and UI prototype**. It implements a robust event-sourced architecture using SQLite and Lua, with a high-performance C++ rendering layer for the timeline visualization.

**Crucially, this appears to be a "Database & Logic" implementation.** There is no evidence of a real-time video playback engine, audio mixer, or pixel processing pipeline in the reviewed files. The application creates, manages, and visualizes the *structure* of a video project (sequences, clips, tracks) but does not appear to *play* the video content itself (the Viewer is text-based).

The system is well-architected in terms of separation of concerns between the C++ View/OS layer and the Lua Business Logic layer. However, it suffers from a critical **Timebase Disconnect** (Integers vs. Floats) that threatens data integrity, and several "God Objects" in the Lua layer that hamper maintainability.

## Critical Architecture Flaws

### 1. The Timebase Disconnect (Severity: Critical)
*   **Issue:** The database schema correctly defines `start_value` and `duration_value` as `INTEGER` (ticks). However, the application logic (Lua) consistently treats time as **floating-point milliseconds**.
*   **Evidence:**
    *   `src/lua/core/frame_utils.lua`: Uses `tolerance_ms` for frame alignment (impossible in integer math).
    *   `src/lua/importers/fcp7_xml_importer.lua`: Calculates time as `(frames / rate) * 1000` resulting in floats.
    *   `src/lua/core/command_implementations.lua`: Directly passes these float values to the database, relying on implicit SQLite casting or potential truncation.
*   **Impact:** Guaranteed off-by-one frame errors, gaps between clips, and drift over long sequences. 29.97fps content cannot be accurately represented in integer milliseconds.

### 2. "God Object" Monoliths (Severity: High)
*   **`src/lua/core/command_implementations.lua`**: 6,000+ lines. Contains logic for *all* commands (Create, Delete, Move, Ripple, etc.). It mixes SQL transaction logic, JSON serialization, and business rules.
*   **`src/lua/ui/project_browser.lua`**: 2,000+ lines. Manages tree UI, drag-and-drop, selection state, and file system interactions.
*   **Impact:** Extremely difficult to test or refactor individual features. Merge conflicts are inevitable.

### 3. Testing Facade (Severity: Critical)
*   **Issue:** `test_ripple_operations.lua` mocks the database, the models, and even the *command execution logic* itself.
*   **Impact:** The tests pass, but they verify a "simulated" version of the logic, not the actual code running in `command_implementations.lua`. The production code is effectively untested.

## Subsystem Analysis

### 1. Persistence Layer (Solid Foundation)
*   **Schema (`schema.sql`):** Well-designed event-sourcing model. The `commands` table stores every action, enabling robust Undo/Redo and crash recovery.
*   **Gap:** Missing `UPDATE` triggers to prevent clip overlapping (only exists for `INSERT`).
*   **Importers:** The `resolve_database_importer.lua` is a standout feature, allowing direct imports from DaVinci Resolve's SQLite format.

### 2. User Interface (Hybrid Architecture)
*   **Concept:** "Lua-driven UI". C++ provides generic widgets (`ScriptableTimeline`, `LuaTreeWidget`), and Lua configures them.
*   **Timeline:** `ScriptableTimeline.cpp` is a performant retained-mode renderer. It receives draw commands (Rect, Line, Text) from Lua. This is an excellent design choice for keeping complex UI logic hot-reloadable.
*   **Inspector:** `src/lua/ui/inspector/view.lua` implements a complex Schema-driven UI entirely in Lua. It's powerful but complex.

### 3. Media Management (Metadata Only)
*   **Implementation:** `media_reader.lua` uses `ffprobe` via `io.popen`.
*   **Limitations:** It extracts metadata (resolution, codec, duration) but there is no decoding pipeline. The "Viewer" (`viewer_panel.lua`) displays this metadata as text, confirming the "Offline/Data Manager" nature of current state.

### 4. Project Browser (Functional but Bloated)
*   **Functionality:** Mimics professional NLE bins/trees effectively. Handles drag-and-drop to timeline (logic exists in `project_browser.lua` `handle_tree_drop`).
*   **Code Quality:** Needs splitting into `BrowserModel`, `BrowserView`, and `BrowserController`.

## Recommendations

1.  **Immediate Remediation (Timebase):**
    *   Stop using `ms` (milliseconds) as the unit of time.
    *   Adopt a `Rational` (num/den) or `Tick` (e.g., 1/254016000000 sec) based system in Lua.
    *   Rewrite `frame_utils.lua` to strictly enforce integer frame boundaries based on the sequence frame rate.

2.  **Refactoring Strategy:**
    *   **Explode `command_implementations.lua`**: Create a `src/lua/commands/` directory. Each command (e.g., `MoveClip`) gets its own file implementing a standard interface (`execute`, `undo`).
    *   **Extract Data Access**: Move SQL queries out of UI files (`project_browser.lua`) and into `models/*.lua` or specific Data Access Objects (DAOs).

3.  **Safety Nets:**
    *   Add `BEFORE UPDATE` triggers to `schema.sql` to enforce clip non-overlap at the database level.
    *   Write *Integration Tests* that spin up a real in-memory SQLite DB and execute real commands.

4.  **Future Trajectory:**
    *   To become a "Video Editor", a C++ video rendering engine (using FFmpeg/mpv/QtMultimedia) must be integrated to replace the text-based Viewer and draw actual frames in the Timeline.

## Conclusion
JVE is a technically impressive "NLE Project Management System". The data architecture is professional-grade (Event Sourcing + SQLite). The UI architecture (C++ Host / Lua Scripting) is flexible and modern. The primary risks are the floating-point time calculations and the monolithic Lua scripts. Fixing the timebase is the prerequisite for any serious video editing functionality.