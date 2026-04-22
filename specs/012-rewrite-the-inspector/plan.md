# Implementation Plan: Inspector Panel Rewrite

**Branch**: `012-rewrite-the-inspector` | **Date**: 2026-04-19 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/Users/joe/Local/jve-spec-kit-claude/specs/012-rewrite-the-inspector/spec.md`

## Summary

Rewrite the Inspector panel to comply with ENGINEERING.md and CLAUDE.md MVC rules. The existing module is 1,452 LOC of `view.lua` plus orphaned `adapter.lua`, `selection_inspector.lua`, `widget_pool.lua`, and a dead `main_window.lua`. The rewrite preserves every current user-visible behavior (schema-driven form, single-edit via command system, multi-edit with Apply, mark summary, search filter, project/content change refresh), adds `read_only` field flag, persists section collapse state across sessions, and corrects rule-violating patterns (pcall-swallowed Qt failures, fallback values, duplicated refresh paths, hardcoded styling, global scratch helpers, 2.15 back-compat shims, dead modules).

Technical approach: split `view.lua` into cohesive single-responsibility files (bootstrap/mount, schema & field widget factory, selection binding, change listeners), introduce a new `persistent_widget.lua` in `src/lua/core/` for FR-021a collapse persistence, delete the four dead modules and `widget_pool.lua` entirely, promote `TIMECODE` to a distinct property type end-to-end in `inspectable/clip.lua` and `inspectable/sequence.lua`, and land `--test`-mode integration scripts 1:1 with the 14 Acceptance Scenarios plus pure-logic unit tests for the decomposable invariants.

## Technical Context

**Language/Version**: Lua (LuaJIT) + C++ (Qt6)
**Primary Dependencies**: Qt6 (via `qt_bindings.cpp` → `qt_constants.lua`), SQLite, `core/command_manager`, `core/signals`, `ui/selection_hub`, `ui/collapsible_section`, `inspectable/{clip,sequence}.lua`
**Storage**: Project DB (SQLite `.jvp` files) for model state; new persistence file for collapse state (format resolved in Phase 0 — see research.md)
**Testing**:
- Unit tests: LuaJIT scripts in `tests/` run by `./tests/run_lua_tests_all.sh` against Qt stubs
- Integration tests: `./build/bin/JVEEditor --test <script>` executes Lua inside the full C++ process with real Qt bindings, one script per Acceptance Scenario (FR-033)
**Target Platform**: macOS (primary), Qt6 desktop
**Project Type**: Single project (Scriptable Video Editor; Lua UI over C++ Qt foundation)
**Performance Goals**: Selection-change → rendered Inspector update well under one frame (< 16 ms) on a clip with the full schema; no blocking calls on the UI thread.
**Constraints**:
- No new field types beyond STRING, TEXT_AREA, DROPDOWN, INTEGER, DOUBLE, BOOLEAN, TIMECODE
- No new clip/sequence properties (properties deferred to features that introduce their consumer)
- No changes to `selection_hub`, `command_manager`, or the `inspectable` factory (spec non-goals)
- No pcall-swallowing of Qt binding failures (FR-024)
- No fallback values on required data (FR-025)
- Model-View pull-on-notify; single refresh channel (`content_changed`) drives refresh (FR-016, FR-026)
**Scale/Scope**: ~13 in-scope clip properties + ~9 in-scope sequence properties (per Phase 0 research, tightened by /analyze I1 which removed viewport_start_time and viewport_duration from the sequence schema). 14 Acceptance Scenarios + 3 /analyze-driven integration scenarios (17 total, mapped 1:1 to `--test` scripts). 6 FR-032 unit tests + 5 /analyze-driven unit tests (11 total). Expected net code change is a **reduction**: delete ~2,000 LOC of dead/duplicative code; new implementation projected at ~1,100 LOC split across the new Inspector modules plus `persistent_widget.lua`.

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluating against `.specify/memory/constitution.md` v2.0.0:

| Principle | Status | Notes |
|---|---|---|
| **I. Modular Architecture / MVC** | PASS | Plan splits the monolith into single-responsibility modules. Views pull from model on `content_changed`; no imperative push (FR-016, FR-026). |
| **II. Command-Driven Interface** | PASS | Every edit routes through `command_manager` (FR-011, FR-012, FR-028). Multi-edit uses a single undo group via `begin_command_event("ui")`. No ad-hoc mutation paths. |
| **III. Test-First Development** | PASS | 14 `--test` scripts mapped 1:1 to Acceptance Scenarios (FR-033) + pure-logic unit tests (FR-032). Tests land and fail first. |
| **IV. Documentation-Driven Specifications** | PASS | Spec has 3 clarification sessions; Phase 0 research produces concrete property enumeration (FR-023c) and migration table (FR-023e). |
| **V. Template-Based Consistency** | PASS | Using spec/plan/tasks templates as written. |
| **VI. Fail-Fast Assert Policy** | PASS | FR-024 (no pcall-swallowing), FR-017b (assert on missing inspectable), FR-025 (assert on missing required data) are explicit requirements. |
| **VII. No Fallbacks or Default Values** | PASS | FR-025 codifies this. All `or 0` / `or ""` / `or <default>` on required data in current code are being removed. |
| **VIII. No Backward Compatibility** | PASS | FR-030 / FR-031 mandate deletion of dead code and legacy aliases. No shims, no migrations. |

**Initial Constitution Check: PASS.** No violations to document; no complexity tracking needed.

## Project Structure

### Documentation (this feature)
```
specs/012-rewrite-the-inspector/
├── plan.md                        # this file (/plan output)
├── research.md                    # Phase 0 output
├── data-model.md                  # Phase 1 output
├── quickstart.md                  # Phase 1 output
├── contracts/                     # Phase 1 output
│   ├── inspector-api.md               # public API seen by layout.lua and selection_hub
│   ├── inspectable-contract.md        # contract the Inspector expects from inspectable/*.lua
│   └── schema-definition-contract.md  # shape of the restructured metadata_schemas module
├── spec.md                        # already exists
└── tasks.md                       # Phase 2 output — NOT created by /plan
```

### Source Code (repository root)

```
src/lua/
├── ui/inspector/
│   ├── init.lua                 # NEW — public API facade (mount, update_selection, get_focus_widgets)
│   ├── mount.lua                # NEW — scaffold: search row, selection label, scroll area, Apply button
│   ├── schema.lua               # NEW — build_schema_for_id, activate_schema, search filter
│   ├── field_widget.lua         # NEW — create_inspector_field + per-entry methods (set_value, get_value, set_mixed, set_error, dirty)
│   ├── selection_binding.lua    # NEW — update_selection, load_single / load_multi, majority-schema + tiebreak
│   ├── change_listeners.lua     # NEW — project_changed + content_changed handlers (single pull-on-notify channel)
│   ├── view.lua                 # DELETE — 1,452 LOC monolith
│   ├── adapter.lua              # DELETE — dead
│   └── widget_pool.lua          # DELETE — no live reclamation; flattened per Q2
├── core/
│   ├── persistent_widget.lua    # NEW — cross-session widget-state primitive (FR-021a)
│   └── runtime/controller/selection_inspector.lua  # DELETE — dead controller
├── ui/
│   ├── main_window.lua          # DELETE — orphaned; uses stale `scripts.*` require paths
│   ├── timeline/timeline_panel.lua  # EDIT — remove set_inspector stub (line 395)
│   ├── project_browser.lua      # EDIT — remove set_inspector storage (line 1668) after confirming unread
│   └── metadata_schemas.lua     # RESTRUCTURE — prune stale sections; add read_only; Resolve-style grouping; only in-scope fields
└── inspectable/
    ├── clip.lua                 # EDIT — add TIMECODE branch at :set boundary
    └── sequence.lua             # EDIT — add TIMECODE branch at :set boundary

tests/
├── unit/inspector/                              # FR-032 + /analyze additions — pure-logic unit tests (Qt stubs)
│   ├── test_filter_matching.lua
│   ├── test_majority_schema_tiebreak.lua
│   ├── test_mixed_value_detection.lua
│   ├── test_timecode_parse_format.lua
│   ├── test_pending_edit_discard.lua
│   ├── test_read_only_commit_suppression.lua
│   ├── test_persistent_widget_roundtrip.lua     # /analyze G2
│   ├── test_resolve_inspectables.lua            # /analyze U1
│   ├── test_compute_mode.lua                    # /analyze U1
│   ├── test_property_type_mapping.lua           # /analyze U1
│   └── test_invalid_input_state_machine.lua     # /analyze G3 (pure state)
├── integration/inspector/                       # FR-033 + /analyze additions — --test mode
│   ├── scenario_01_single_clip_browser.lua
│   ├── scenario_02_timeline_clip_mark_summary.lua
│   ├── scenario_03_single_sequence.lua
│   ├── scenario_04_single_field_edit.lua
│   ├── scenario_05_undo_round_trip.lua
│   ├── scenario_06_redo_round_trip.lua
│   ├── scenario_07_multi_edit_mixed.lua
│   ├── scenario_08_apply_multi_edit.lua
│   ├── scenario_09_majority_schema_mixed.lua
│   ├── scenario_10_read_only_multi.lua
│   ├── scenario_11_search_filter.lua
│   ├── scenario_12_project_change_clears.lua
│   ├── scenario_13_content_changed_refresh.lua
│   ├── scenario_14_inspector_source_no_recurse.lua
│   ├── scenario_15_pull_missing_inspectable_asserts.lua   # /analyze G1 (FR-017b)
│   ├── scenario_16_invalid_input_state_transitions.lua    # /analyze G3 (FR-015a/b/c)
│   └── scenario_17_mid_edit_external_mutation_race.lua    # /analyze G4 (FR-016a/b)
└── test_inspector_modules.lua                   # DELETE — tests the dead adapter
```

**Structure Decision**: Single-project Lua + C++ hybrid. No change to the repo-wide layout. Inspector becomes a multi-file module under `src/lua/ui/inspector/` with a single public facade `init.lua`. Dead modules are deleted rather than archived (rules 2.15 / 2.17).

## Phase 0: Outline & Research

Phase 0 complete. See `research.md`. Three parallel audits (property enumeration, existing UI enumeration, contract audit of surrounding systems) resolved every `/plan`-deferred open item from the spec:

- **FR-023c property enumeration**: 13 in-scope clip properties + 15 in-scope sequence properties. No schema "zombies" — every column is either read by a consumer or is structural identity/audit metadata.
- **FR-023e existing UI inventory**: 5 form-editing UIs to migrate; 2 specialized-tool surfaces to keep coexisting; 2 dead code locations to delete.
- **Contract audit**: `persistent_widget.lua` does not exist today even though rule 1.6 presumes it — this feature ships the minimal primitive. Other contracts (selection_hub, Signals, command_manager, inspectable, collapsible_section, qt_constants, ui_constants) are stable and usable as-is.
- **Most-recently-clicked tiebreak (FR-005a)**: since selection_hub doesn't preserve click order and the spec non-goal forbids changing it, Inspector tracks tiebreak locally via "first item in the new selection that was not present in the previous selection; if none, first item."
- **content_changed scope**: single channel emitted at `command_manager.lua:199`. Inspector matches on `sequence_id` and pulls.
- **Self-triggered notifications**: an inspector commit fires `content_changed` that re-enters; the pull returns the just-committed value (idempotent). A nested-edit guard (`suppress_field_updates`) is still required around programmatic `set_value` calls inside `load_single`/`load_multi`.

**Output**: `research.md` with property tables, UI classification, contract API summary, and resolutions.

## Phase 1: Design & Contracts

Artifacts generated:

1. **`data-model.md`** — Inspector entities and their state transitions: `Inspector` (module state), `SelectionState` (size, schemas present, active-schema choice, prev-selection-ids for tiebreak stability, source_panel), `ActiveSchema`, `FieldWidget` (value, pending_value, dirty flag, error flag, mixed flag, read_only flag), `SectionState` (persisted collapsed/expanded), `PropertyPayload` with distinct TIMECODE variant, and the `content_changed` + `project_changed` signal contracts the Inspector consumes.

2. **`contracts/inspector-api.md`** — Three public functions only: `mount(container_widget)`, `update_selection(items, source_panel_id)`, `get_focus_widgets()`. No init/ensure_search_row/set_header_text/set_batch_enabled/get_filter/set_filter/save_all_fields (all deleted per FR-027, FR-031).

3. **`contracts/inspectable-contract.md`** — Signatures unchanged from today (non-goal protects the factory) except the `payload` to `:set` now supports `property_type == "TIMECODE"` as a distinct branch; payload carries `{value = <int frames>, property_type = "TIMECODE", default_value = nil|<int frames>}`. Rate remains single-sourced on the owning entity.

4. **`contracts/schema-definition-contract.md`** — Restructured `metadata_schemas.lua`: sections (ordered list), fields (key, label, type, default?, options?, read_only?), lookup entry points `get_sections(schema_id)` and `get_field(schema_id, field_key)`. Resolve-style grouping for clips (File, Source Range, Audio, Metadata) and sequences (Project, Viewport, Marks). Stale sections (premiere, review, crop, composite, transform) pruned per Phase 0.

5. **`quickstart.md`** — How to run the unit tests, the 14 `--test` integration scripts, and the full `make -j4`. Includes a manual-validation checklist covering every spec Acceptance Scenario plus the deletion-is-selection-change invariant.

6. **Agent context update** — append new tech choices (`persistent_widget`, TIMECODE end-to-end) via `./.specify/scripts/bash/update-agent-context.sh claude`.

**Post-Design Constitution Check: PASS.** No new violations introduced by the concrete design. Single-responsibility modules, pull-on-notify, fail-fast asserts, no fallbacks, no back-compat, dead code deleted.

## Phase 2: Task Planning Approach

*This section describes what `/tasks` will do. Do not execute during `/plan`.*

**Task generation strategy:**

1. From each contract file, generate one contract test. Each test must fail before its target exists.

2. From the 14 Acceptance Scenarios in `spec.md`, generate 14 `--test` integration scripts under `tests/integration/inspector/`. Each is named `scenario_NN_<shortname>.lua` with a 1:1 mapping. All must fail until the full Inspector lands.

3. From the FR-032 invariant list, generate 6 unit tests under `tests/unit/inspector/`.

4. Implementation tasks in TDD order:
   - **Phase A — setup and failing tests**: create empty module stubs so tests can `require`; write all contract + unit + integration tests; verify all fail.
   - **Phase B — contract fulfillment, bottom-up**:
     - Implement `persistent_widget.lua` (smallest, no Inspector coupling).
     - Restructure `metadata_schemas.lua` (prune stale, add `read_only`, reorder).
     - Add TIMECODE branch to `inspectable/clip.lua` + `inspectable/sequence.lua`.
     - Implement `field_widget.lua` (pure widget factory with dirty / error / read_only).
     - Implement `schema.lua` (build + activate + filter).
     - Implement `selection_binding.lua` (update_selection, majority-schema, tiebreak, multi-edit Apply).
     - Implement `change_listeners.lua` (single content_changed + project_changed channel).
     - Implement `mount.lua` (scaffold; pull styles from `ui_constants`).
     - Implement `init.lua` (three-function public facade).
   - **Phase C — integration**: rewire `layout.lua` to `require("ui.inspector")` (the new facade). Run the 14 `--test` scripts. All must pass.
   - **Phase D — cleanup**: delete `view.lua`, `adapter.lua`, `widget_pool.lua`, `selection_inspector.lua`, `main_window.lua`, `test_inspector_modules.lua`, the `timeline_panel.set_inspector` stub, and the `project_browser.set_inspector` storage (after confirming unread). Run `make -j4`; luacheck must pass with zero warnings.

5. **Ordering and parallelism**: tasks touching disjoint files are marked `[P]`. Tests come before their implementation target. Deletion is last so the old code never stops running while the new code is partially landed.

**Estimated output**: 35–40 numbered tasks in `tasks.md`.

**IMPORTANT**: Phase 2 is executed by `/tasks`, NOT by `/plan`.

## Phase 3+: Future Implementation

- **Phase 3**: `/tasks` generates `tasks.md`.
- **Phase 4**: implementation execution (manual or via `/implement`).
- **Phase 5**: validation — full `make -j4`, run the 14 `--test` scripts, manual quickstart walkthrough, luacheck zero warnings.

## Complexity Tracking

No Constitution Check violations. The `persistent_widget.lua` addition is not a new complexity source — ENGINEERING.md rule 1.6 already mandates the mechanism as MANDATORY; this feature merely builds the primitive that was assumed to exist.

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (/plan command)
- [x] Phase 1: Design complete (/plan command)
- [x] Phase 2: Task planning complete (/plan command — approach described only)
- [x] Phase 3: Tasks generated (/tasks command)
- [x] Phase 4: Implementation complete (partial — core done unsupervised 2026-04-20; widget-level integration tests deferred; see tasks.md "Implementation Summary")
- [ ] Phase 5: Validation passed (manual walkthrough pending Joe's review)

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved (Q1–Q4, Q7, Q-Hetero, property-existence scope, UI migration & classification, read-only flag, section persistence, test strategy, deletion semantics, mid-edit external-mutation conflict, invalid-input state; Q5/Q6 deferred to implementation as cosmetic only)
- [x] Complexity deviations documented (none — no violations)

---
*Based on Constitution v2.0.0 — see `.specify/memory/constitution.md`*
