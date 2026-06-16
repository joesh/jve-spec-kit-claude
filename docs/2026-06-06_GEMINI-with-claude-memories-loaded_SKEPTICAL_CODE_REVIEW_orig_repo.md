# Skeptical Code Review: Branch 023-resolve-color-bridge

**Reviewer:** Gemini CLI (Interactive Agent)
**Date:** Sunday, June 7, 2026
**Scope:** `master..HEAD` on branch `023-resolve-color-bridge` (+35,473 / −2,281 lines)

## Executive Summary
The `023-resolve-color-bridge` branch introduces the bridge infrastructure and grade/edit sync logic between JVE and DaVinci Resolve. While the feature set is substantially complete and the core architecture (Metal renderer, Supervisor lifecycle) is robust, the implementation suffers from **significant mandate violations** regarding SQL isolation and test discipline. A **critical production-blocking bug** exists in the `DeleteTimeline` verb. Additionally, the sync algorithms contain **performance bottlenecks** (N-query loops) that will degrade with timeline scale.

---

## 1. Critical & Production-Blocking Findings

### [CRITICAL] Incorrect `DeleteTimelines` Call Site
- **Location:** `tools/resolve-helper/verbs.py:871`
- **Finding:** The code calls `project.DeleteTimelines([target])`. In the DaVinci Resolve Scripting API, `DeleteTimelines` is a method of the `MediaPool` object, not the `Project` object.
- **Impact:** Any attempt to delete a timeline via the bridge (e.g., during test cleanup or user action) will fail with a `'NoneType' object is not callable` or attribute error.
- **Architectural Violation:** This is a known bug acknowledged in `MEMORY.md` (2026-06-03) but shipped nonetheless. Violation of **"Good result > Fast process"** and **"No lazy shortcuts"**.

### [HIGH] SQL Isolation Violation (Mandate 2.29)
- **Locations:** 
  - `src/lua/core/commands/sync_grades_from_resolve.lua:382`
  - `src/lua/core/commands/sync_edits_from_resolve.lua:143`
  - `src/lua/core/commands/connect_to_resolve_project.lua:133`
- **Finding:** These commands call model-layer functions (`Sequence.load`, `Track.find_at`, `Track.find_by_sequence`) without passing a `db` parameter. The model functions hardcode a call to `resolve_db()`, which retrieves the global connection.
- **Impact:** Breaks transaction-scoped isolation required by the `command_manager`. Direct SQL access in commands bypasses the intended architectural boundary.
- **Violation:** Violation of **"Commands can't call database.get_connection()"** and the **SQL Isolation policy**.

---

## 2. Architectural & Performance Findings

### [HIGH] Brittle & Inefficient Startup Race Mitigation
- **Location:** `src/lua/core/resolve_bridge/helper_supervisor.lua:104-114`
- **Finding:** The `wait_for_bind` function uses `os.execute("test -S " .. socket_path)` without quoting or escaping the `socket_path`. Additionally, it forks a `sleep` process every 25ms in a loop.
- **Impact:** 
  - **Brittleness:** If `TMPDIR` contains a space, the bridge will fail to start as the shell command will be malformed.
  - **Performance:** Forking two processes every 25ms during startup is inefficient and blocks the main thread, violating **"Good result > Fast process"**.
- **Architectural Violation:** Violation of **"No lazy shortcuts"**. The implementation is a functional hack rather than a robust solution.

### [HIGH] N-Query SQL Loop in Response Translation
- **Location:** `src/lua/core/commands/sync_edits_from_resolve.lua:143`
- **Finding:** Inside `translate_wire_response`, `Track.find_at` is called inside a loop over every clip in the Resolve response.
- **Impact:** A timeline with 500 clips results in 500 separate SQL queries. This should be a single bulk query loading all tracks for the sequence into a lookup table.
- **Architectural Correctness:** Violation of **"Measure the reported-slow path first"** (preventative) and general performance standards.

### [MEDIUM] O(N*M) Content Matching in Identity Ledger
- **Location:** `src/lua/core/resolve_bridge/identity_ledger.lua:285` (calling `find_content_match`)
- **Finding:** `find_content_match` performs a linear scan of `resolve_items` for every `pending_no_direct` clip.
- **Impact:** O(N*M) complexity for positional fallback matching. For large timelines, this will cause a noticeable UI hitch during sync.
- **Fix Recommendation:** Bucket `resolve_items` by `file_uuid` (as done for `blade_inherit`) to reduce search space.

### [MEDIUM] redundant `rebuildVertexBuffer` and Metal Allocation
- **Location:** `src/gpu_video_surface.mm:430`
- **Finding:** `rebuildVertexBuffer` creates a `newBufferWithBytes` every time rotation changes. While not a hot loop, the renderer's `renderTexture` also performs `MTLTextureDescriptor` checks.
- **Positive Note:** `setFrameSW` and `setLut3D` correctly reuse textures, adhering to **"Never malloc in hot loops"**.

---

## 3. DRY & Maintainability Findings

### [MEDIUM] Redundant Track Type & FPS Normalization
- **Locations:** 
  - `src/lua/core/commands/sync_edits_from_resolve.lua:51`
  - `src/lua/core/commands/connect_to_resolve_project.lua:60`
  - `src/lua/core/resolve_bridge/payload_builder.lua:149`
- **Finding:** Mapping between JVE (`VIDEO`/`AUDIO`) and Resolve (`video`/`audio`) is repeated across multiple bridge-related files.
- **Impact:** Divergence risk as more track types are added.

### [LOW] FPS Math Duplication
- **Location:** `src/lua/core/resolve_bridge/payload_builder.lua:40/96`
- **Finding:** `fps_numerator / fps_denominator` math and assertions are repeated.
- **Violation:** Violation of **"Lift DRY at the third copy"**.

---

## 4. Test Compliance & Quality Findings

### [HIGH] Mandate Violation: Poking Live Resolve in Contract Tests
- **Location:** `tests/binding/test_helper_read_grades.lua:123` / `tests/binding/helper_fixture.lua:60`
- **Finding:** Contract tests explicitly check for and exercise a live Resolve connection if present.
- **Violation:** **"Contract tests must not poke live Resolve... do NOT exercise the live API"** (`GEMINI.md`).

### [HIGH] Mandate Violation: Forbidden Test Bootstrap Pattern
- **Location:** `tests/integration/ui_test_env.lua:62` (`create_test_project`)
- **Finding:** Uses `db.init()`, `project:save()`, and `seq:save()` raw bootstrap.
- **Violation:** **"Tests drive via user-visible primitives (commands/UI), NEVER database.init() or raw schema bootstrap"**.

### [MEDIUM] Direct SQL in Binding Tests
- **Location:** `tests/binding/test_import_resolve_timeline.lua:32`
- **Finding:** Uses `database.get_connection()` and raw `SELECT` for state verification.
- **Violation:** **"No DB terminology outside the model layer"** and **"Tests drive via user-visible primitives"**.

---

## 5. Positive Highlights
- **Tetrahedral Interpolation:** Implementation in `gpu_video_surface.mm` follows Resolve/FFmpeg standards for higher color fidelity.
- **Metal Pipeline Robustness:** Use of `static_assert` for CdlUniform layout prevents silent memory corruption between C++ and Metal.
- **Supervisor Lifecycle:** `wait_for_bind` and unique socket paths correctly handle process race conditions and parallel instance safety.
- **Smoke Runner:** Excellent environment isolation and authentic UI-ONLY driving via `cliclick` and `osascript`.

---

## Claims
1. `DeleteTimelines` call site error — confirmed in `verbs.py:871` and `MEMORY.md` (2026-06-03).
2. SQL Isolation violations — confirmed in `sync_grades_from_resolve.lua:382` and `sync_edits_from_resolve.lua:143`.
3. N-query loop in `sync_edits` — confirmed in `src/lua/core/commands/sync_edits_from_resolve.lua:143`.
4. O(N*M) matching in ledger — confirmed in `src/lua/core/resolve_bridge/identity_ledger.lua:285` via `find_content_match`.
5. Contract tests poke live Resolve — confirmed in `tests/binding/test_helper_read_grades.lua:123`.
6. Forbidden test bootstrap — confirmed in `tests/integration/ui_test_env.lua:62`.
7. Tetrahedral interpolation upgrade — confirmed in `src/gpu_video_surface.mm:201-269`.
8. `last_command_error` missing from `debug_helpers.lua` — confirmed by `grep` and smoke test skips.
