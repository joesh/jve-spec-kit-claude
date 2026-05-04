# Implementation Plan: Source-in-Timeline + Track-Header Redesign + Tristate Sync-Lock

**Branch**: `015-source-in-timeline` | **Date**: 2026-05-03 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification at `/Users/joe/Local/jve-spec-kit-claude/specs/015-source-in-timeline/spec.md`

## Summary

Add a **single Source tab** to JVE's timeline panel (one viewer for the source-monitor's loaded master sequence, blue accent), a **paired src/rec patch-button** track-header redesign with cell order `paired src/rec id buttons → label → lock icon → sync-mode → S/M stack` (lock BEFORE sync-mode, matching FR-008), a **per-track tristate sync-mode** (Off/Ripple/Cut) cycling on the track header, **patches** as a new persisted entity (per-source-track on/off + drag-redirect routing), and **unified Solo/Mute on both audio AND video** tracks. The feature ALSO fixes a pre-existing bug where Solo/Mute/Lock toggles incorrectly land on the per-sequence undo stack — they (and the new patch & sync-mode toggles) become explicitly **non-undoable session preferences** persisted to the project DB but skipping `snapshots`.

Approach: extend existing systems rather than parallel ones. Tab system extension uses `timeline_panel.lua` `open_tabs`. Sync-mode dispatch inserts BEFORE `inject_implicit_gap_edges` in the existing ripple pipeline. New `patches` table; new `sync_mode` column on existing `tracks`. New `non_undoable` SPEC flag on commands for the 6 toggle commands.

## Technical Context

**Language/Version**: Lua (LuaJIT 2.1) for UI/command/data layers; C++17 (Qt 6.x) for performance-critical timeline/render layers (no C++ changes anticipated by this feature).
**Primary Dependencies**: existing `core/command_manager`, `core/signals`, `core/ripple/batch/pipeline`, `core/clip_mutator`, `models/track`, `ui/timeline/timeline_panel`, `ui/source_viewer`, `ui/panel_manager`. SQLite (lsqlite3) for project persistence. JSON in `~/.jve/` for per-user app preferences.
**Storage**: SQLite `.jvp` project files. Forward-only migration: add `tracks.sync_mode` column; create `patches` table. Per-user preference `source_routing_view` persists as JSON in `~/.jve/` alongside existing prefs (`recent_projects.json`, `file_browser_paths.json`, etc.).
**Testing**: LuaJIT-based `tests/test_*.lua` via `test_harness.lua`. Integration tests via `./build/bin/JVEEditor --test <script>` for paths needing real Qt bindings (track-header rendering, drag interactions). Black-box, non-trivial values, real DB.
**Target Platform**: macOS primary (development); Linux/Windows secondary.
**Project Type**: single project, hybrid Lua+C++ desktop app. Source layout already established at `src/lua/` and `src/cpp/`.
**Performance Goals**: tab switch perceived-instant (FR-007a — no observable storage round-trip). Ripple performance unchanged (Cut branch performs at most one extra split per affected clip — no ripple-pipeline asymptotic regression). Solo/Mute/Lock toggle: latency unchanged from today (already not heavyweight; only undoability changes).
**Constraints**: rule 1.14 fail-fast asserts at every patch lookup, sync-mode dispatch, displayed-tab switch, etc. (FR-047 enumerates 8 sites). Rule 2.13 no fallbacks (FR-029a OFF-drop is intentional, NOT a fallback). Rule 2.15 forward-only schema (FR-046 — no migration code preserves prior behavior). Rule 2.20 regression-test-first for the FR-040a bug fix.
**Scale/Scope**: typical project ~1000 clips/sequence; 8-channel BWF field recordings common; multiple open record sequences; one active source at a time.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution version 2.0.0 (`.specify/memory/constitution.md`):

| Principle | Status | Justification |
|---|---|---|
| **I. Modular Architecture** | PASS | New entities (Patch) and the new `sync_mode` column live in their own modules. Source tab is an annotation on the existing tab system, not a parallel module. Ripple-pipeline extension is a single dispatch point at a known existing location. |
| **II. Command-Driven Interface** | PASS | All 6 toggle paths (patch on/off, patch drag-redirect, sync-mode, solo, mute, lock) and the new "Show Source Tab" go through `command_manager` (rule 1.10). |
| **III. Test-First Development (NON-NEGOTIABLE)** | PASS | FR-048 enumerates the test surface; FR-040a explicitly invokes rule 2.20 ("ALWAYS add a failing regression test BEFORE fixing a bug"). Tests are black-box and use non-trivial values (8-channel BWF, multi-clip sequences). |
| **IV. Documentation-Driven Specifications** | PASS | Spec covers all FRs with Clarifications session 2026-05-03 resolving all open `[NEEDS CLARIFICATION]` markers (zero remain in body). |
| **V. Template-Based Consistency** | PASS | Following spec/plan/tasks template. |
| **VI. Fail-Fast Assert Policy** | PASS | FR-047 enumerates 8 explicit assert sites with offending-id-in-message requirement. |
| **VII. No Fallbacks or Default Values** | PASS | FR-029a (OFF-drop is user-controlled, not silent failure), FR-035 (no silent drop of routing failures), FR-013/14 (P+R buttons fully removed, not stubbed). |
| **VIII. No Backward Compatibility** | PASS | FR-046 forward-only schema migration; rule 2.15 explicit. No old-project migration code. |

**No violations.** No Complexity Tracking entries needed.

## Project Structure

### Documentation (this feature)

```
specs/015-source-in-timeline/
├── plan.md              # This file (/plan output)
├── spec.md              # /specify + /clarify output (already complete)
├── research.md          # Phase 0 output (this command)
├── data-model.md        # Phase 1 output (this command)
├── quickstart.md        # Phase 1 output (this command)
├── contracts/           # Phase 1 output (this command)
│   ├── command-specs.md         # Command SPEC tables (existing pattern)
│   ├── signals.md               # Signal contracts (Signals.emit/connect)
│   └── schema-migration.md      # Schema delta for forward migration
└── tasks.md             # Phase 2 output (/tasks command — NOT created here)
```

### Source Code (repository root)

JVE's existing single-project layout. This feature touches:

```
src/
├── lua/
│   ├── core/
│   │   ├── command_manager.lua            # extend: support `non_undoable` SPEC flag
│   │   ├── signals.lua                    # add: source_tab_visibility_changed, displayed_tab_changed, active_sequence_changed, patch_changed, sync_mode_changed
│   │   ├── snapshot_manager.lua           # consult: existing snapshot path; new flag bypasses it
│   │   └── commands/
│   │       ├── set_track_property.lua     # split / refactor — non-undoable for solo/mute/lock/enabled (FIXES FR-040a BUG)
│   │       ├── add_track.lua              # consult: existing track-creation; called from FR-029b auto-create
│   │       ├── set_patch.lua              # NEW (this feature) — non-undoable; ON/OFF + record_track_index
│   │       ├── set_sync_mode.lua          # NEW (this feature) — non-undoable
│   │       ├── show_source_tab.lua        # NEW (this feature) — undoable open/close action; opens an existing master in the timeline strip
│   │       └── batch_ripple_edit.lua      # extend: per-track sync_mode dispatch BEFORE inject_implicit_gap_edges
│   ├── core/ripple/batch/pipeline.lua     # extend: dispatch hook
│   ├── models/
│   │   ├── track.lua                      # add: sync_mode field accessor
│   │   └── patch.lua                      # NEW (this feature)
│   ├── ui/
│   │   ├── source_viewer.lua              # consult: load_master_clip(master_seq_id)
│   │   ├── panel_manager.lua              # consult: get_sequence_monitor("source_monitor")
│   │   └── timeline/
│   │       ├── timeline_panel.lua         # extend: tab styling for SourceTab; extend track header (lines 1029-1296); auto-create track at edit time
│   │       └── timeline_state.lua         # extend: displayed_tab_id, active_sequence_id pointers (independent)
│   └── schema.sql                         # forward-only migration (FR-046): tracks.sync_mode column + patches table
├── cpp/                                   # NO C++ changes anticipated
└── ...

tests/
├── test_set_patch.lua                     # NEW
├── test_set_sync_mode.lua                 # NEW
├── test_track_preference_non_undoable.lua # NEW (regression test for FR-040a bug)
├── test_source_tab.lua                    # NEW
├── test_displayed_vs_active_pointer.lua   # NEW
├── test_cut_branch_split_spanning_clip.lua # NEW
├── test_auto_create_record_track.lua      # NEW
├── test_modifier_drag_stack.lua           # NEW (uses --test mode for Qt drag)
└── ...
```

**Structure Decision**: single-project hybrid Lua+C++ layout (existing). New files added under `src/lua/core/commands/`, `src/lua/models/`, `src/lua/schema.sql`; new tests under `tests/`. No new top-level directory required.

## Phase 0: Outline & Research

**Output**: [`research.md`](./research.md) — generated this command.

Research covered:
1. Existing snapshot mechanism (`command_manager.lua`) — confirmed `skip_clip_snapshot` and `skip_selection_snapshot` flags exist; need a NEW `non_undoable` flag for FR-040 commands. **Decision**: add `non_undoable` SPEC flag.
2. Existing solo/mute/lock command (`set_track_property.lua`) — registers undoer, hence on undo stack today (FR-040a bug). **Decision**: split into ToggleTrackPreference (non_undoable) and SetTrackMixValue (existing undoable) OR mark SetTrackProperty as non_undoable when the property is solo/mute/lock/enabled.
3. Tab system in `timeline_panel.lua` — `open_tabs` is per-sequence; SourceTab is an annotation on the tab whose sequence_id matches `source_monitor`'s loaded master. **Decision**: extend the existing system, no new tab kind.
4. Source viewer in `source_viewer.lua:14` — `load_master_clip(master_seq_id)` is the entry point. Source clips ARE master sequences. **Decision**: SourceTab follows the source monitor's loaded master, no new "source-clip" entity.
5. Ripple pipeline — dispatch hook lives at `core/ripple/batch/pipeline.lua` before `inject_implicit_gap_edges` (`batch_ripple_edit.lua:488`). **Decision**: insert per-track sync_mode branch at the existing pre-injection hook.
6. PersistentWidget — not a literal class. JVE persists app prefs via JSON files in `~/.jve/`. **Decision**: per-user `source_routing_view` preference persists in `~/.jve/source_routing_view.json` (or extend `recent_projects.json`-style convention).
7. Track creation — `add_track.lua` exists. **Decision**: FR-029b auto-create reuses this command in the same undoable transaction as the edit.

All `[NEEDS CLARIFICATION]` markers in spec are resolved (zero remaining).

## Phase 1: Design & Contracts

**Output**:
- [`data-model.md`](./data-model.md) — entity definitions, schema deltas, validation rules
- [`contracts/command-specs.md`](./contracts/command-specs.md) — command SPEC tables for `SetPatch`, `SetSyncMode`, `ShowSourceTab`, refactored `SetTrackProperty`
- [`contracts/signals.md`](./contracts/signals.md) — new signals: `source_tab_visibility_changed`, `displayed_tab_changed`, `active_sequence_changed`, `patch_changed`, `sync_mode_changed`, `track_preference_changed`
- [`contracts/schema-migration.md`](./contracts/schema-migration.md) — explicit forward-only SQL deltas
- [`quickstart.md`](./quickstart.md) — end-to-end smoke test for the feature

Agent file (CLAUDE.md) updated by `update-agent-context.sh` at end of Phase 1.

## Phase 2: Task Planning Approach

*This section describes what the /tasks command will do — DO NOT execute during /plan.*

**Task Generation Strategy**:
- Load `.specify/templates/tasks-template.md` as base.
- Generate tasks ordered by dependency:
  1. **Schema migration first** (data-model.md): new `sync_mode` column, new `patches` table, schema version bump. Tests for migration.
  2. **Command framework extension**: add `non_undoable` SPEC flag to `command_manager.lua`. Tests for the flag (no snapshot row, no undo entry).
  3. **FR-040a regression test FIRST** (rule 2.20): test asserts toggling solo/mute/lock produces no `snapshots` row and is NOT Cmd-Z reverted. Test MUST FAIL on current codebase. Demonstrate the failure, commit the failing test.
  4. **Split SetTrackProperty** (or add `non_undoable` conditionally): solo/mute/lock/enabled become non-undoable. The previously-failing regression test now passes.
  5. **New `Patch` model + commands**: `models/patch.lua`, `core/commands/set_patch.lua` (non_undoable). Tests for create/delete/modify.
  6. **New `SetSyncMode` command** (non_undoable). Tests including all three branches' invariants (FR-026 post-conditions).
  7. **Ripple pipeline dispatch**: insert per-track sync_mode branch in `batch_ripple_edit.lua` before `inject_implicit_gap_edges`. Tests for Off/Ripple/Cut behavior including spanning-clip auto-split.
  8. **`timeline_state` pointers**: add `displayed_tab_id` and `active_sequence_id` (independent). Tests for FR-005 (Source-tab click does NOT change active sequence).
  9. **Track-header refactor** (`timeline_panel.lua` lines 1029-1296): new cell order; remove P + R; lock SVG icon; sync-mode cell; S/M vertical stack. Tests via `--test` mode where Qt rendering matters.
  10. **SourceTab** styling + ShowSourceTab command + close-with-x. Tests for empty placeholder (FR-007b), open/close persistence.
  11. **Patch UI**: paired src/rec id buttons, on/off, drag-redirect (plain), modifier-drag-stack. Tests via `--test` mode.
  12. **Per-channel vs per-clip view** (FR-029c): preference + view-toggle modifier (FR-029d). Tests for view flip without DB write.
  13. **Auto-create record track** (FR-029b): edit-time AddTrack call inside the same undoable transaction. Tests.
  14. **3-point math + ghost mark**: tab-independent computation. Tests including the "active sequence is target while SourceTab displayed" invariant (FR-038).
  15. **Final integration test (quickstart.md)**: end-to-end editor flow with 8-ch source onto 3-ch record + sync-mode + close+reopen.

**Ordering Strategy**:
- TDD order: failing test → implementation → green
- Dependency order: schema → command framework → models → commands → pipeline integration → UI → integration tests
- `[P]` for parallel execution where files are independent (e.g., `Patch` model + `SetSyncMode` command can be developed in parallel after schema lands)

**Estimated Output**: 30–40 numbered, ordered tasks in tasks.md.

**IMPORTANT**: This phase is executed by `/tasks` command, NOT by `/plan`.

## Phase 3+: Future Implementation

Beyond /plan scope.

**Phase 3**: Task execution (/tasks creates tasks.md from this plan).
**Phase 4**: Implementation (TDD, commit per task per rule 2.20).
**Phase 5**: Validation — run `make -j4` (luacheck + Lua tests + C++ build), execute quickstart.md manually, verify FR-048 test surface coverage.

## Complexity Tracking

*Empty — no constitutional violations to justify.*

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (`research.md`)
- [x] Phase 1: Design complete (`data-model.md`, `contracts/`, `quickstart.md`)
- [x] Phase 2: Task planning approach described (above)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS (all 8 principles)
- [x] Post-Design Constitution Check: PASS (no new violations introduced by Phase 1 artifacts)
- [x] All NEEDS CLARIFICATION resolved (Clarifications 2026-05-03)
- [x] Complexity deviations documented (none)

---
*Based on Constitution v2.0.0 — see `.specify/memory/constitution.md`*
