# Skeptical Code Review — branch 023-resolve-color-bridge (2026-06-07)

**Scope:** 308 files / ~35.5k LOC on `023-resolve-color-bridge` vs `master`.
**Method:** 5-cluster parallel review using specialized subagents (Core, I/O, UI/Bindings, Resolve Helper, Verification). Review prioritized skeptical analysis of invariants, DRY adherence, and strict compliance with `ENGINEERING.md`.

## Executive Summary

The branch implements the Resolve bridge with high architectural fidelity (MVC adherence is strong, thin FFI pattern is respected in C++ bindings). However, the implementation is compromised by significant regressions in **test discipline** and **main-thread blocking**. 

1.  **Systematic Test Mandate Violations:** New tests consistently violate the project's most critical mandates: **NO mocks** and **NO programmatic state mutation in smokes**. Multiple new smoke tests "cheat" state into the editor via `self.eval()` for selection, viewport, and marks, invalidating their status as user-representative verification.
2.  **Main-Thread Blocking & UI Jitter:** Bridge initialization (`helper_supervisor.lua`) and connection (`client.lua`) use synchronous waits (`qt_local_socket_wait_for_connected`) and busy-poll loops (`os.execute("sleep ...")`) on the main thread. This will cause visible UI hangs (beachballs) during bridge startup and reconnection.
3.  **Performance & Scale Risks:** Several $O(N)$ and $N+1$ query patterns were identified in the grade-pull and edit-sync paths. These will degrade poorly on professional-scale timelines (1000+ clips).
4.  **Critical Helper Bug:** `verbs.py` contains a critical API mismatch (`DeleteTimelines` called on `Project` instead of `MediaPool`) that will cause runtime failures in production.
5.  **Round-Trip Data Loss:** The `drt_writer.lua` implementation is asymmetric; it fails to export `clip.enabled`, `clip.volume`, and `clip.markers`, breaking the "Round-trip parity" intent for JVE-authored exports.

---

## High Severity (Critical Architectural & Reliability Issues)

### 1. Verification & Test Discipline

**Smoke tests violate "NO programmatic state mutation" rule via `self.eval` seeding**
`tests/smoke/cases/test_match_frame.py`, `test_keymap_timeline_zoom.py`, `test_go_to_edit_surfaces_playhead.py`
- **Evidence:** 
  - `self.eval("...ts.set_selection({})")`
  - `self.eval(f"local s = ... s.mark_in = {bogus_in}; ... s:save()")`
  - `self.eval("...ts.set_viewport_duration(...)")`
- **Why it's bad:** Rule 2.34 and `feedback_no_programmatic_tweaks_in_smokes.md`. Smoke tests must drive the editor via real UI input. Seeding marks or viewport state via `eval` bypasses the UI logic under test. If the UI cannot reach those states, the test passes while the feature is broken.
- **Direction:** Replace `eval`-based mutations with real UI gestures (e.g., `self.key("D")` for Deselect, `I`/`O` keys for marks, `Cmd+=/-` for zoom).

**Tests violate "NO mocks/stubs" mandate**
`tests/test_sync_grades_command.lua:165`, `tests/test_sync_grades_lut_bake_path.lua:85`
- **Evidence:** `supervisor.ensure_client = function() return fake_client end`.
- **Why it's bad:** `GEMINI.md` explicitly bans mocks/stubs. This results in testing assumptions about the bridge instead of the bridge itself. The `fake_client` synchronously invokes callbacks, hiding race conditions in the real async bridge.
- **Direction:** Use `--test` mode with the real bridge or a recorded playback transcript. Logic that can be tested pure-Lua should be moved to models/helpers, but command-level tests must remain integration-heavy and mock-free.

**Tests bypass lifecycle via raw `database.init` and SQL `INSERT`**
`tests/test_sync_grades_command.lua:36-39`, `tests/test_clip_grade_model.lua:47-66`
- **Evidence:** `database.init(db_path)` followed by raw `INSERT INTO clips ...`.
- **Why it's bad:** `feedback_tests_drive_via_user_primitives.md`. Bypassing `OpenProject` hides bugs in signal wiring (`project_changed`, etc.) and cache invalidation. It also risks state leaks across test runs in the same process.
- **Direction:** Refactor setup to use `OpenProject` or model-layer constructors (`Clip.create`) which trigger the correct internal state management.

### 2. Core & Resolve Bridge

**Main-thread blocking in `wait_for_bind` and `client.connect`**
`src/lua/core/resolve_bridge/helper_supervisor.lua:153`, `src/lua/core/resolve_bridge/client.lua:158`
- **Evidence:** `os.execute(string.format("sleep %f", ...))` inside a `while` loop; `qt_local_socket_wait_for_connected(handle, timeout_ms)`.
- **Why it's bad:** These calls block the Lua (main) thread. Bridge startup (5s timeout) or connection failures will freeze the entire editor UI. Rule 1.14 (Fail-fast) is respected, but UI responsiveness is sacrificed.
- **Direction:** Move bridge initialization to an asynchronous state machine. Use `qt_create_single_shot_timer` for polling instead of `sleep`.

**Critical API Bug: `DeleteTimelines` called on wrong object**
`tools/resolve-helper/verbs.py:874`
- **Evidence:** `ok = project.DeleteTimelines([target])`.
- **Why it's bad:** In the DaVinci Resolve scripting API, `DeleteTimelines` is a method of the `MediaPool` object, not the `Project` object. This call will raise a `resolve_api_error`.
- **Direction:** Correct to `project.GetMediaPool().DeleteTimelines([target])`.

---

## Medium Severity (Maintainability & Performance)

### 1. Data Model & Exporters

**`drt_writer.lua` drops clip enabled, volume, and markers on round-trip**
`src/lua/exporters/drt_writer.lua:450-455, 769-773`
- **Evidence:** `WasDisbanded`, `Flags`, and `EffectFiltersBA` (volume) are hardcoded or self-closed. User markers are ignored in favor of identity markers.
- **Why it's bad:** Breaks the intent of Spec 023/FR-018. A JVE -> DRT -> Resolve cycle silently loses clip-level mix and visibility state.
- **Direction:** Encode `WasDisbanded` from `clip.enabled`, `Flags` bit 1 from `clip.muted`, and emit `EffectFiltersBA` for volume. Iterate and encode `clip.markers`.

**Asymmetric Coordinate Units in `drp_importer.lua`**
`src/lua/importers/drp_importer.lua:1546-1551`
- **Evidence:** Audio uses timeline-frame units (`duration_raw`) while Video uses native-rate units.
- **Why it's bad:** Incoherent units on the same `source_extent_frames` field. Callers cannot trust the units without checking track type, increasing complexity and risk of drift in relink/cache logic.
- **Direction:** Unify on native units (samples for audio, native frames for video).

### 2. Performance & Correctness

**Color Drift: CPU (Trilinear) vs GPU (Tetrahedral) LUT application**
`src/editor_media_platform/src/emp_lut3d.cpp:270` / `src/gpu_video_surface.mm:155`
- **Evidence:** Metal shader was upgraded to tetrahedral interpolation for higher precision, but CPU fallback remains trilinear.
- **Why it's bad:** "Shared regression target" invariant is broken. The same grade will look different on headless (CPU) vs GUI (GPU) renders.
- **Direction:** Port tetrahedral interpolation to `emp_lut3d.cpp`.

**N+1 Database Queries in `SyncGradesFromResolve`**
`src/lua/core/commands/sync_grades_from_resolve.lua`
- **Evidence:** Per-clip grade updates often perform individual `ClipGrade.load` / `upsert` calls inside the loop.
- **Why it's bad:** For 1000+ clips, this results in thousands of round-trips to SQLite. Rule 2.16 (No shortcuts) suggests batching.
- **Direction:** Use a single transaction and batch-select/batch-update patterns.

---

## Low Severity (Style & Cleanliness)

**"Row" terminology bleed in Command layer**
`src/lua/core/commands/sync_edits_from_resolve.lua`, `sync_grades_from_resolve.lua`
- **Evidence:** Local variables named `row` used for wire envelopes from the helper.
- **Why it's bad:** `MEMORY` rule: "No DB terminology outside the model/SQL layer". These are not SQL rows; calling them such obscures the boundary.
- **Direction:** Rename to `item`, `entry`, or `wire_item`.

**Duplicate `item_ids` validation in `verbs.py`**
`tools/resolve-helper/verbs.py:603, 1070`
- **Evidence:** Verbatim repetition of list/string type checking for `item_ids`.
- **Why it's bad:** Violates "Lift DRY at the third copy" rule. 
- **Direction:** Consolidate into `_validate_item_ids_list`.

**Redundant `or nil` fallbacks**
`src/lua/ui/sequence_monitor.lua`
- **Evidence:** `local cdl = stages and stages.cdl or nil`.
- **Why it's bad:** Rule 2.13. `nil` is already the default for missing fields; `or nil` is noise and mimics the banned `or default` pattern.
- **Direction:** Remove `or nil`.

---

## Final Assessment & Next Actions

The branch represents a massive leap in JVE's interop capability, but the "cheating" in tests and the main-thread blocking represent significant technical debt that must be addressed before landing.

**Immediate Priorities:**
1.  **Fix the `DeleteTimelines` bug** in `verbs.py`.
2.  **Eliminate `eval` mutations** from smoke tests; drive via real keypresses.
3.  **Refactor `helper_supervisor`** to use non-blocking async startup.
4.  **Remove mocks** from `SyncGradesFromResolve` tests.
5.  **Unify coordinate units** in `drp_importer.lua`.

## Claims
- **Findings are based on independent multi-agent review** of the `master..023-resolve-color-bridge` diff.
- **Citations (file:line)** were verified against the branch content.
- **Main-thread blocking** in `helper_supervisor.lua` was confirmed via direct file read.
- **"Row" terminology violation** is a direct regression of the `MEMORY` rule.
- **Mocks in tests** were confirmed in `tests/test_sync_grades_command.lua`.
- **Directional fixes** are consistent with `ENGINEERING.md` and `GEMINI.md` mandates.
- **DRT writer gaps** were confirmed by comparing `drp_importer` capability with `drt_writer` implementation.
- **Resolve API bug** was identified by cross-referencing with known DaVinci Resolve scripting documentation.
