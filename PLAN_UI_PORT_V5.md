# JVE UI V5 Porting Plan

**Goal:** Migrate the UI layer from Legacy V4 (milliseconds/float FPS) to V5 (Rational/Frames) to match the "Scorched Earth" core architecture.

## 1. Principles
*   **Rational Everywhere:** UI components must accept, store, and pass `Rational` objects for all time values.
*   **Rate Structs:** Frame rates are `{fps_numerator, fps_denominator}` tables, not floats.
*   **No Local Math:** Do not perform arithmetic (`/ 1000.0`, `* frame_rate`) locally. Use `Rational` methods or `frame_utils`.
*   **Fail Fast:** Explicitly check for `Rational` types and error if legacy numbers are passed.

## 2. Component Audit & Changes

### 2.1 `src/lua/ui/project_browser.lua`
Currently uses `format_duration(ms, float_rate)` and creates commands with number params.

*   **Update `format_duration`:**
    *   Input: `Rational` duration, `Rate` struct.
    *   Logic: Use `frame_utils.format_timecode(duration_rat, rate_struct)`.
*   **Update `populate_tree`:**
    *   `media.duration` / `clip.duration` are now `Rational` (from `database.lua` V5 loader).
    *   `media.frame_rate` / `clip.frame_rate` are `Rate` structs.
    *   Pass these directly to updated `format_duration`.
*   **Update `insert_selected_to_timeline`:**
    *   Retrieve `Rational` playhead position from `timeline_state`.
    *   Construct `Insert` command with `Rational` parameters (`insert_time`, `duration`, `source_in`, `source_out`).
*   **Update `create_sequence_in_project`:**
    *   `sequence_defaults` should return `Rate` struct.
    *   Pass `Rate` struct components to `CreateSequence` command.

### 2.2 `src/lua/ui/viewer_panel.lua`
Displays source/timeline time. Likely uses float/ms.

*   **Update `show_source_clip`:**
    *   Expect `payload` with `Rational` duration/rate.
    *   Update internal state to store `Rational`.
    *   Update timecode display to use `frame_utils` with Rationals.
*   **Update `show_timeline`:**
    *   Handle `Rational` sequence duration/rate.

### 2.3 `src/lua/ui/inspector/view.lua`
Edits properties. Critical for modifying data.

*   **Update Timecode Fields:**
    *   Input: Expect `Rational` value.
    *   Display: Convert `Rational` -> Timecode String (using `frame_utils`).
    *   Edit: Parse Timecode String -> `Rational` (using `frame_utils`).
    *   Save: Pass `Rational` to `command_manager` (e.g., `SetClipProperty`).
*   **Update Frame Rate Fields:**
    *   Display as string (e.g. "24 fps" or "23.976 fps" derived from num/den).

### 2.4 `src/lua/ui/layout.lua`
Initializes default data.

*   **Verify:** Ensure `ensure_default_data` inserts correct V5 columns (already patched, verify consistency).

## 3. Dependencies

### 3.1 `src/lua/core/database.lua`
The bridge between DB and UI.

*   **Verify:** `load_media`, `load_master_clips`, `load_sequences`, `load_clips` must return `Rational` objects for time columns and `Rate` structs for rates.
    *   *Self-Correction:* I previously updated `build_clip_from_query_row` to return Rationals. Need to verify `load_media` and others do the same.

### 3.2 `src/lua/core/frame_utils.lua`
*   **Verify:** Ensure `format_timecode` handles `Rational` input correctly (it does).

## 4. Execution Steps
1.  **Refactor `project_browser.lua`** (High priority, source of recent crashes).
2.  **Refactor `viewer_panel.lua`**.
3.  **Refactor `inspector/view.lua`**.
4.  **Verify `database.lua` loaders**.
5.  **Run App & Verify**.

