# Implementation Plan: Source-viewer live-bound clip mode + narrow trim-mode toggle

**Branch**: `019-source-viewer-clip-mode` | **Date**: 2026-05-19 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/Users/joe/Local/jve-spec-kit-claude/specs/019-source-viewer-clip-mode/spec.md`

## Execution Flow (/plan command scope)
```
1. Load feature spec from Input path                           ✅ loaded
2. Fill Technical Context (scan for NEEDS CLARIFICATION)        ✅ no NEEDS CLARIFICATION (Clarifications Sessions 1 + 2)
3. Fill the Constitution Check section                          ✅ filled against v2.0.0
4. Evaluate Constitution Check section below                    ✅ one justified deviation (Complexity Tracking)
5. Execute Phase 0 → research.md                                ✅ generated
6. Execute Phase 1 → contracts, data-model.md, quickstart.md    ✅ generated
7. Re-evaluate Constitution Check section                       ✅ still passes
8. Plan Phase 2 → Task generation approach                      ✅ described
9. STOP — Ready for /tasks command                              ✅
```

## Summary

**Primary requirement** (from spec): Source viewer supports a new **live-bound clip mode** entered via Shift+F or timeline double-click. In this mode the viewer holds a `clips`-table row (not a sequence); its in/out marks ARE the clip's `source_in_frame`/`source_out_frame`; pressing I/O retrims the clip live on the timeline via `RippleTrimEdge` (existing) or a new `OverwriteTrimEdge` based on a narrow session-transient toggle (default overwrite). The viewer's effective-source contract is amended to carry `(in, out)` overrides drawn from the loaded clip so Insert/Overwrite into the record timeline use the clip's source bounds. Browser activation is refactored to dispatch through three new commands (`OpenSequenceInSourceMonitor`, `OpenSequenceInTimeline`, `OpenClipInSourceMonitor`). Inspector picks up the loaded entity through the existing item_type pathway (no new schema).

**Technical approach** (from research, post-2026-05-19 scope-trim): source viewer stores `(mode, live_clip_id)` and binds playback by calling the existing `SequenceMonitor:load_sequence(clip.sequence_id)` — same code path staged mode uses; no in-memory holding-sequence wrap. Mark-setter dispatch routes through existing `RippleTrimEdge` (ripple path) or the new `OverwriteTrimEdge` (peer command, ~80 LOC) based on `core/edit_mode.get_trim_mode()`. Signal-driven re-resolve (FR-004b) and auto-unload (FR-004a) reuse existing Sequence/Clip mutation/deletion signals. No schema change.

## Technical Context

**Language/Version**: LuaJIT 2.1 (UI, commands, source viewer state, edit_mode module) + C++17/Qt6 (one new mouse-event binding for timeline double-click only)
**Primary Dependencies**: existing modules — `core/command_manager`, `core/signals`, `core/effective_source` (FR-016d amends contract), `core/commands/ripple_trim_edge` + `core/commands/batch_ripple_edit` (reused), `models/sequence`, `models/clip`, `ui/panel_manager`, `ui/focus_manager`, `ui/sequence_monitor`, `ui/source_viewer`, `ui/selection_hub`, `ui/project_browser`, `core/commands/match_frame` (binding unchanged), `keymaps/default.jvekeys` (keybinding additions), `view_bindings.cpp` (one new event binding)
**Storage**: SQLite `.jvp` project files — **NO schema change in 019**. Live-bound state is process-resident (`live_clip_id`); no in-memory entity, no DB row. `clips.source_in_frame` / `source_out_frame` mutated by `RippleTrimEdge`/`OverwriteTrimEdge` are existing columns. Trim-mode toggle is process-state only, not persisted.
**Testing**: LuaJIT harness (`tests/test_*.lua`); existing `tests/run_lua_tests_all.sh` runs the full suite. Integration test for the timeline double-click + Qt binding uses `./build/bin/JVEEditor --test <script.lua>` per CLAUDE.md guidance.
**Target Platform**: macOS desktop (primary). Linux/Windows untested but should work — only Qt-binding code (one new connection) is platform-aware.
**Project Type**: single (existing JVE structure: `src/lua/`, `src/`, `tests/`).
**Performance Goals**: live-bound mark-set dispatch latency < 50ms per press (perceived-instant). Auto-repeat suppressed (FR-016b) so no per-frame command flood. Holding-sequence construction must not stall the UI thread (< 5ms target — in-memory object).
**Constraints**: zero luacheck warnings; all 844 existing Lua tests continue to pass; no `make` regressions. Spec-mandated NSF discipline (rule 1.14, 2.13, 2.32). Cross-spec contract amendment to 015 implemented in lockstep (FR-016d + 015 forward-pointing note).
**Scale/Scope**: single source viewer instance per project. One live-bound clip at a time. Trim-mode toggle is a single boolean. Browser refactor touches 3 new commands + the existing `activate_item` router. Estimated source-code delta: ~600 LOC Lua + ~30 LOC C++ + ~250 LOC tests.

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against constitution v2.0.0 (`.specify/memory/constitution.md`):

**I. Modular Architecture (MVC)**: ✅ — Source viewer (view) holds in-memory state (`mode`, `live_clip_id`), pulls from model on signals. Edit_mode module is self-contained (no UI deps). No new entity introduced — playback binds through the existing `SequenceMonitor:load_sequence(clip.sequence_id)` path used by staged mode.

**II. Command-Driven Interface**: ✅ — Every new user-facing operation is a registered command: `OverwriteTrimEdge`, `OpenClipInSourceMonitor`, `OpenSequenceInSourceMonitor`, `OpenSequenceInTimeline`, `ToggleTrimMode`. All keybindable, discoverable in keyboard customization dialog. Retrim mutations route through command_manager (FR-013) so undo works.

**III. Test-First Development (NON-NEGOTIABLE)**: ✅ — Task list opens each command implementation with a failing test (T1, T2, T4, T5, T6, T7, T8, T9). FR-031 enumerates 5 named test files.

**IV. Documentation-Driven Specifications**: ✅ — spec.md complete with 9 clarifications (2 sessions), 37+ FRs, Cross-spec touches section, Out-of-scope section. Implementation follows spec.

**V. Template-Based Consistency**: ✅ — plan.md uses `.specify/templates/plan-template.md`.

**VI. Fail-Fast Assert Policy**: ✅ — explicit asserts pinned in FR-009 (edit_mode enum validation), FR-015 (OverwriteTrimEdge preconditions), FR-027 (timeline double-click on gap-as-clip rejected with logged event). No silent fallbacks. `clip_label` derivation reframed as sentinel selection (FR-016f) rather than fallback after Session 2 audit.

**VII. No Fallbacks or Default Values**: ✅ — FR-016f's title `clip_label` is a sentinel (deterministic title from row data), not a fallback masking an error. Mark-setter dispatch (FR-013) reads `edit_mode.get_trim_mode()` which asserts on missing value. Effective_source pass-through (FR-016d) carries explicit `(in, out)` — no silent defaulting.

**VIII. No Backward Compatibility**: ⚠️ — ONE controlled deviation: `source_viewer.load_master_clip` retained as a thin alias to the new `source_viewer.load_sequence` until spec 020 lands. See **Complexity Tracking** below for justification.

## Project Structure

### Documentation (this feature)
```
specs/019-source-viewer-clip-mode/
├── plan.md              # This file (/plan output)
├── spec.md              # Authoritative spec (Clarifications Sessions 1 + 2)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output — entities + state transitions
├── quickstart.md        # Phase 1 output — manual validation script
├── contracts/           # Phase 1 output — command contracts
│   ├── overwrite_trim_edge.md
│   ├── open_clip_in_source_monitor.md
│   ├── open_sequence_in_source_monitor.md
│   ├── open_sequence_in_timeline.md
│   ├── toggle_trim_mode.md
│   ├── source_viewer_load_clip.md
│   └── effective_source_pass_through.md
└── tasks.md             # Phase 2 (/tasks output — NOT created here)
```

### Source Code (repository root)
Existing single-project layout (`src/lua/`, `src/`, `tests/`). 019 touches:

```
src/lua/
├── core/
│   ├── edit_mode.lua                              [NEW] FR-008..012
│   ├── effective_source.lua                       [MODIFY] FR-016d (carry in/out overrides)
│   └── commands/
│       ├── overwrite_trim_edge.lua                [NEW] FR-014, FR-015
│       ├── open_clip_in_source_monitor.lua        [NEW] FR-017
│       ├── open_sequence_in_source_monitor.lua    [NEW] FR-018
│       ├── open_sequence_in_timeline.lua          [NEW] FR-019
│       ├── toggle_trim_mode.lua                   [NEW] FR-011
│       └── set_marks.lua                          [MODIFY] FR-016c (disable in live-bound)
├── ui/
│   ├── source_viewer.lua                          [MODIFY] FR-002..007, FR-013, FR-016a..f, FR-028..030
│   ├── sequence_monitor.lua                       [MODIFY] FR-016e (playback-range branch on mode)
│   ├── project_browser.lua                        [MODIFY] FR-020..022 (activate_item routes through commands)
│   └── timeline/view/
│       └── timeline_view_input.lua                [MODIFY] FR-026 (double-click dispatch)

src/qt_bindings/
└── view_bindings.cpp                              [MODIFY] FR-026 (timeline-clip double-click Qt binding)

keymaps/
└── default.jvekeys                                [MODIFY] FR-024, FR-025

tests/                                             [NEW + EXTEND]
├── test_overwrite_trim_edge.lua                   FR-031 [NEW]
├── test_edit_mode_toggle.lua                      FR-031 [NEW]
├── test_source_viewer_load_clip.lua               FR-031 [NEW]
├── test_open_clip_in_source_monitor.lua           FR-031 [NEW]
├── test_browser_activation_routes_through_commands.lua  FR-031 [NEW]
├── test_live_bound_key_repeat_suppressed.lua      FR-016b [NEW]
├── test_live_bound_play_ignores_marks.lua         FR-016e [NEW]
├── test_clear_marks_disabled_in_live_bound.lua    FR-016c [NEW]
├── test_timeline_double_click_dispatches_open_clip.lua  FR-026, FR-027 [NEW]
├── test_source_viewer_publishes_selection.lua     [EXTEND — live-bound scenario]
├── test_effective_source.lua                      [EXTEND — override channel scenarios per FR-016d]
├── test_match_frame.lua                           [UNCHANGED — F-key behavior preserved]
└── test_source_viewer_signal.lua                  [UNCHANGED — staged-mode signal contract preserved]

specs/015-source-in-timeline/spec.md               [ALREADY MODIFIED in this session — forward-pointing note]
specs/020-rename-master-to-media-sequence/         [UNTOUCHED — 019 ships first; 020's renames sweep through 019's new code]
```

**Structure Decision**: single-project layout; this is a feature add to the existing JVE Lua + Qt6 hybrid. No new top-level directories. Two-plus new Lua command files plus modifications to four existing Lua files plus one C++ binding file plus the keymap file plus five new test files.

## Phase 0: Outline & Research

See `research.md` for the full Phase-0 output. Summary:

**Resolved during /clarify** (Sessions 1 + 2 — see spec.md ## Clarifications):
- Clip-deletion-while-loaded → auto-unload + signal (FR-004a)
- Playhead post-retrim → stays put (FR-016a)
- Browser modifier → Opt+Return only (FR-022)
- Key-repeat → suppressed via `QKeyEvent::isAutoRepeat()` filter (FR-016b)
- Clear marks in live-bound → disabled (FR-016c)
- Effective-source contract in live-bound → pass-through with `(in, out)` overrides (FR-016d, amends 015)
- Play with playhead-outside-marks → marks gate edit-bounds only (FR-016e)
- Source viewer title in live-bound → `"Source: <clip_label> (in <owner_sequence_name>)"` (FR-016f)
- Non-trim mutation while loaded → full re-resolve (FR-004b)

**Open spikes**: none. The 2026-05-19 scope-trim dropped the holding-sequence concept; the playback-engine in-memory-sequence question that spike T3 was going to answer no longer applies — staged-mode's existing `SequenceMonitor:load_sequence(clip.sequence_id)` path is the live-bound playback bind.

## Phase 1: Design & Contracts

See `data-model.md`, `contracts/*`, `quickstart.md`. Summary:

**Entities** (existing — no new schema):
- `clips` row — mutated by `OverwriteTrimEdge` and `RippleTrimEdge` via existing model paths
- `sequences` row — unchanged in scope
- **Holding sequence** — NEW in-memory entity, not persisted, owned by source-viewer state

**Contracts**:
- 5 new commands (each with full SPEC.args, executor semantics, undoability)
- 1 modified contract: `effective_source.get()` return shape
- Source-viewer module public API: `load_clip(clip_id, opts)`, `load_sequence(sequence_id, opts)` (renamed from `load_master_clip` with one-session alias), `unload()`

**Quickstart** (manual validation script): step-by-step user-flow walkthrough exercising Acceptance Scenarios 1-8 + the I/O retrim cycle + the trim-mode toggle.

**Agent context update**: `update-agent-context.sh claude` to inject 019's new technologies (none beyond existing — Lua + Qt6) and modules into root `CLAUDE.md`.

## Phase 2: Task Planning Approach
*This section describes what `/tasks` will produce — do NOT execute during /plan.*

**Task generation strategy**:
- Load `.specify/templates/tasks-template.md` as base
- Each contract file in `contracts/` → contract test task [P] (parallel — independent files)
- Each entity in `data-model.md` → model construction / extension task
- Each user-facing scenario (Acceptance 1-8) → integration test task
- One implementation task per command/module
- One refactor task per modified existing file (4 Lua + 1 C++)

**Ordering strategy** (TDD + dependency-first):
1. `core/edit_mode` module + `ToggleTrimMode` (T2 in current task list — leaf dependency)
2. `OverwriteTrimEdge` command (T1) — depends on existing Clip + BatchRippleEdit
3. `source_viewer.load_clip` (T13) — depends on T10 (`core/edit_mode`) + T12 (`OverwriteTrimEdge`); binds playback via existing `SequenceMonitor:load_sequence(clip.sequence_id)`
5. `OpenClipInSourceMonitor` + Shift+F (T5) — depends on T4
6. Timeline double-click (T6) — depends on T5
7. Selection-hub publish + effective_source amendment (T7) — depends on T4
8. Browser command refactor (T8) — depends on T7 (effective_source amendment)
9. Browser Opt+Return (T9) — depends on T8
10. Pre-commit audit + full Lua suite (T10) — depends on all of the above

Parallel windows: T2 and T1 are independent (no shared file), so both can be in flight; T5 can begin as soon as T4 unblocks even if T6/T7 haven't started; T9 can be drafted alongside T8 since the keymap file edit doesn't conflict with command code.

**Estimated Output**: 10-12 numbered tasks in tasks.md (one per source/test file unit). Most map 1:1 to the existing in-session task list (T1-T10).

## Phase 3+: Future Implementation
**Phase 3**: `/tasks` produces `tasks.md`.
**Phase 4**: Execute tasks per the constitution (TDD, fail-fast, no fallbacks).
**Phase 5**: Run `tests/run_lua_tests_all.sh` (must be 844+ passing); run `make -j4` (zero luacheck warnings); execute `quickstart.md` manually in a JVE session.

## Complexity Tracking
*One justified deviation from the constitution.*

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **Constitution VIII (No Backward Compatibility)** — keep `source_viewer.load_master_clip` as a thin alias to `source_viewer.load_sequence` during the 019→020 transition window. | 019 ships before 020 (Joe's directive). The function is called from 5 sites (`project_browser.lua:444`, `commands/match_frame.lua:128`, `ui/layout.lua:589`, plus 4 test stubs). Renaming all callsites in 019 = touching files that will all be touched again in 020 anyway. The alias is a one-line forwarding function with an explicit deprecation comment pointing to 020. | Deleting the alias and renaming all 5 callsites in 019 is acceptable code volume, BUT it commits 019 to a touch-pattern that 020 has to re-touch. Doing it twice is duplicate work and risks merge conflicts between sessions working on 019 and 020 simultaneously. The alias is scoped (one function, one comment, removed by 020) and has no runtime cost — literally `function M.load_master_clip(...) return M.load_sequence(...) end`. |

This deviation is removed in spec 020 in lockstep with the global rename — see spec 020 §FR-014 (which renames the function definition and removes all callers; at that point the alias has no consumers and is deleted).

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (research.md generated)
- [x] Phase 1: Design complete (data-model.md, contracts/, quickstart.md generated)
- [x] Phase 2: Task planning approach described (this file §Phase 2; tasks.md NOT generated by /plan)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS (one justified deviation in Complexity Tracking)
- [x] Post-Design Constitution Check: PASS (re-checked after Phase 1; no new violations)
- [x] All NEEDS CLARIFICATION resolved (9 clarifications across 2 sessions)
- [x] Complexity deviations documented (1)

---
*Based on Constitution v2.0.0 — See `.specify/memory/constitution.md`*
