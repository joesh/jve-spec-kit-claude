# Implementation Plan: Uniform Clip Source Timebase with Canonical-Clock Sub-Frame Primitives

**Branch**: `018-uniform-clip-source` | **Date**: 2026-05-18 | **Spec**: `/specs/018-uniform-clip-source/spec.md`
**Input**: Feature specification from `/specs/018-uniform-clip-source/spec.md`

## Execution Status

- [x] Phase 0: Research complete
- [x] Phase 1: Design complete (data-model.md, contracts/, quickstart.md)
- [x] Phase 2: Task planning approach described
- [ ] Phase 3: Tasks generated (`/tasks` command)
- [ ] Phase 4: Implementation
- [ ] Phase 5: Validation

**Gates**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved (Clarifications session 2026-05-18)
- [x] Complexity deviations documented (none — see Complexity Tracking)

## Summary

Settle the contradictory conventions for `clip.source_in_frame` / `source_out_frame` on audio clips into a single uniform convention: integer frame component in the **source sequence's** fps timebase, with sample-precise residual carried in two new INTEGER columns expressed in a **project-wide canonical audio clock** (default 192000 Hz). Drop the master-level `audio_sample_rate` field (audio rate is per-media_ref). Make every sequence's `fps` mutable only via `ConformSequence`, which atomically rewrites all dependent rows. Add `SetProjectDefaultFps` (settings-only, no cascade) and `SetProjectMasterClock` (project-wide subframe rescale). Funnel all clip-source-position reads/writes through a new `clip_position` accessor module — the schema's audio-vs-video distinction (NULL subframe for video, NOT-NULL for audio) becomes structurally impossible to violate at the call site. Importers, edit commands, and the resolver all switch to the accessor module + canonical math primitive. Ships primitives + conform/settings commands + comprehensive test coverage; no UI for `ConformSequence` / `SetProjectDefaultFps` / `SetProjectMasterClock` (deferred to a later UX spec per Clarification Q1).

## Technical Context

**Language/Version**: Lua (LuaJIT 2.1) for the model, command, importer, and edit-command layers; C++17 (Qt 6.x) for any binding-layer touches (none expected — this feature lives entirely above the C++/Qt boundary).

**Primary Dependencies**:
- `lsqlite3` (SQLite 3.x via Lua FFI binding) — schema + triggers
- `core.command_manager`, `core.command_helper`, `core.signals` — existing command-dispatch + undo/redo machinery
- `models.sequence`, `models.clip`, `models.media_ref` — model layer
- `core.database` — DB connection + query helpers
- Existing `Sequence.pick_master_leaf` (sequence.lua:2202–2270) — the leaf resolver, modified to consume subframe + new clip_position API
- Existing importers: `drp_importer.lua`, `fcp7_xml_importer.lua` — rewritten to use new accessor

**Storage**: SQLite `.jvp` project files. Schema bumps from V10 → V11 in this feature.

**Testing**: LuaJIT scripts in `tests/`, harness via `tests/run_lua_tests_all.sh`. C++ integration scenarios run via `JVEEditor --test script.lua` if needed (none anticipated). TDD non-negotiable per Constitution Principle III.

**Target Platform**: macOS (Darwin). Single-user desktop NLE.

**Project Type**: Single project — Lua + C++ hybrid editor; no separate frontend/backend split.

**Performance Goals**: ConformSequence and SetProjectMasterClock must complete in bounded time for a realistic project (≤10k clips). Specific target deferred per Clarification report (research.md captures investigation).

**Constraints**:
- Schema is single-writer; no migration shims (Constitution VIII).
- Old `.jvp` files: hard error on open (Clarification Q2); user re-imports.
- Process crash mid-conform: silent SQLite WAL rollback; defense-in-depth via FR-001/FR-002/FR-031 invariant triggers catching any post-rollback inconsistency (Clarification Q3).
- All clip-position read/write goes through `clip_position` module — no direct field access (FR-009a).

**Scale/Scope**: ~36 functional requirements; estimated 25–35 implementation tasks in tasks.md. Touches schema (3 tables), every importer (2 in scope), every edit command (~7 commands modify source positions), the resolver, the math primitive (new), the accessor module (new), the two new conform/settings commands, and ~10 paired test FRs.

## Constitution Check

All 8 principles satisfied. The spec was written against this constitution; checks below confirm no implementation will need to violate them.

| Principle | Status | Notes |
|---|---|---|
| I. Modular Architecture | ✅ | `clip_position` accessor is a single-responsibility module; conform commands are isolated; subframe math primitive is standalone. |
| II. Command-Driven Interface | ✅ | `ConformSequence`, `SetProjectDefaultFps`, `SetProjectMasterClock` registered via command_manager (FR-029, FR-030a, FR-030b). |
| III. Test-First (NON-NEGOTIABLE) | ✅ | FR-019 through FR-036b enumerate failing-test-first coverage for every new behavior. |
| IV. Documentation-Driven | ✅ | Spec is comprehensive; this plan + research.md + data-model.md + contracts/ + quickstart.md complete the design phase before implementation. |
| V. Template-Based Consistency | ✅ | Plan follows `.specify/templates/plan-template.md`. |
| VI. Fail-Fast Assert Policy | ✅ | FR-001/FR-002/FR-007/FR-024/FR-031 mandate immediate, contextual assertions on every invariant. Schema triggers enforce at the DB layer. |
| VII. No Fallbacks / Defaults | ✅ | FR-007 explicit no-clamp/no-round/no-default; the only "default" is project default fps (FR-026), which is an initialization value, not a read-time fallback. |
| VIII. No Backward Compatibility | ✅ | Schema bump V10→V11; old `.jvp` files hard-error at open (Clarification Q2); no migration shim. |

## Project Structure

### Documentation (this feature)
```
specs/018-uniform-clip-source/
├── spec.md             # Feature specification (complete, post-clarify)
├── plan.md             # This file
├── research.md         # Phase 0 — design tradeoff investigations
├── data-model.md       # Phase 1 — schema + invariants in detail
├── contracts/          # Phase 1 — API contracts
│   ├── clip_position.md   # The DRY accessor module API
│   ├── subframe_math.md   # The canonical math primitive API
│   ├── conform_sequence.md # ConformSequence command contract
│   ├── set_project_default_fps.md
│   └── set_project_master_clock.md
├── quickstart.md       # Phase 1 — end-to-end acceptance test recipe
└── tasks.md            # Phase 2 — generated by /tasks command
```

### Source Code (repository root)

```
src/lua/
├── schema.sql                          # MODIFY: drop master.audio_sample_rate;
│                                       # add clips.source_in_subframe, source_out_subframe (NULLable);
│                                       # add triggers for FR-001 (video=NULL, audio=NOT-NULL),
│                                       # FR-002 (subframe bound), FR-031 (fps single-writer);
│                                       # bump schema_version 10→11.
├── core/
│   ├── clip_position.lua               # NEW: DRY accessor (FR-009a). Sole read/write API.
│   ├── subframe_math.lua               # NEW: canonical math primitive (FR-006, FR-007).
│   ├── database.lua                    # MODIFY: schema_version bump enforcement at open
│   │                                   # (hard error per Clarification Q2).
│   ├── command_manager.lua             # No changes; new commands register normally.
│   └── commands/
│       ├── conform_sequence.lua        # NEW (FR-029).
│       ├── set_project_default_fps.lua # NEW (FR-030a).
│       ├── set_project_master_clock.lua# NEW (FR-030b).
│       ├── insert.lua                  # MODIFY: use clip_position for new clips (FR-013).
│       ├── overwrite.lua               # MODIFY: same.
│       ├── slip.lua                    # MODIFY: preserve subframe (FR-014).
│       ├── roll.lua                    # MODIFY: same.
│       ├── trim_head.lua / trim_tail.lua # MODIFY: same.
│       ├── split.lua                   # MODIFY: same.
│       ├── batch_ripple_edit.lua       # MODIFY: same.
│       └── _place_shared.lua           # MODIFY: subframe-aware mark conversion.
├── models/
│   ├── sequence.lua                    # MODIFY: pick_master_leaf consumes subframe (FR-008);
│   │                                   # round_int helper already matches FR-008 rounding rule.
│   ├── clip.lua                        # MODIFY: route reads through clip_position.
│   └── media_ref.lua                   # MODIFY: drop any master.audio_sample_rate references.
├── importers/
│   ├── drp_importer.lua                # MODIFY: write (frame, subframe) via clip_position (FR-010).
│   └── fcp7_xml_importer.lua           # MODIFY: verify + sub-frame defaults zero (FR-011).
└── gather_context/                     # MODIFY: drop legacy dual-unit accessors (FR-016/FR-017).

tests/
├── test_subframe_math.lua              # NEW (FR-019).
├── test_clip_subframe_persistence.lua  # NEW (FR-020).
├── test_resolver_subframe.lua          # NEW (FR-021).
├── test_drp_importer_subframe.lua      # NEW (FR-022).
├── test_edit_command_subframe_preservation.lua # NEW (FR-023).
├── test_subframe_invariants.lua        # NEW (FR-024).
├── test_overwrite_acceptance_bit_identical.lua # NEW (FR-025).
├── test_master_order_independence.lua  # NEW (FR-033).
├── test_multi_rate_audio_master.lua    # NEW (FR-034).
├── test_conform_sequence.lua           # NEW (FR-035).
├── test_set_project_default_fps.lua    # NEW (FR-036a).
├── test_set_project_master_clock.lua   # NEW (FR-036b).
├── test_schema_version_bump_hard_error.lua # NEW (Clarification Q2).
└── test_clip_position_accessor_chokepoint.lua # NEW (FR-009a — grep-style guard).
```

**Structure Decision**: Single project (Lua + C++ hybrid editor). No separate frontend/backend; the spec touches only Lua-side modules. Test fixtures use existing `test_env.lua` setup.

## Phase 0: Research — `research.md`

Resolved investigations:

1. **Subframe representation: canonical clock vs rational vs per-media_ref**
   - Decision: canonical clock at project-level, default 192000 Hz.
   - Per Clarification — already resolved in spec. research.md records the tradeoff matrix and rejected alternatives.

2. **Sequence.fps single-writer enforcement: SQLite trigger vs Lua-layer guard**
   - Decision: SQLite trigger reading a session flag set by `ConformSequence`. (Constitution V.21 "statically-verifiable" — schema-level is stronger than runtime-only.)
   - research.md captures the trigger pattern and the session-flag mechanism.

3. **Project default fps initialization value**
   - Decision: 24/1 (Clarification Q4 in earlier round; recorded in spec FR-026).

4. **Performance target for `ConformSequence` on large projects**
   - Investigation: SQLite single-transaction with all rewrites batched should comfortably handle 10k-clip projects in <1s on commodity hardware. Confirmed via back-of-envelope (10k UPDATE statements in a single transaction on a local SQLite ≈ 200-400ms typical).
   - Decision: target <500ms p95 for a 10k-clip project; document in research.md. No progress UI in 018 scope (Clarification Q1: no UI).

5. **Schema version-bump open-error path**
   - Decision: `Project.open` reads `schema_version` table; mismatch → fail-fast assert that surfaces through the existing error-dialog facility (per Clarification Q2). research.md verifies the existing error-dialog plumbing handles this path without new UI work.

## Phase 1: Design & Contracts

### `data-model.md`
Schema diff (V10 → V11), all invariant triggers, the (frame, subframe) representation in detail, the audio_sample_rate move from `sequences` to `media_refs` (already there — V10 column on `sequences` is removed), the `projects.settings` JSON shape including `default_fps` and `master_clock_hz` keys.

### `contracts/`
Five contract documents, one per public API surface:
- `clip_position.md` — the DRY accessor (read_audio_source, write_audio_source, read_video_source, write_video_source, plus the sample↔(frame, subframe) helpers).
- `subframe_math.md` — the math primitive (pack, unpack, normalize, samples_to_ticks, ticks_to_samples, validate). Each function's preconditions, postconditions, and assertion messages.
- `conform_sequence.md` — the user-facing command's signature, transactional guarantees, undoability contract, list of rewritten rows by sequence kind.
- `set_project_default_fps.md` — settings-only command contract; explicit no-cascade postcondition.
- `set_project_master_clock.md` — settings + subframe-rescale contract.

### `quickstart.md`
End-to-end recipe to validate the Primary User Story: create a project (fps=24), import a DRP containing a master with non-zero TC and mixed V+A media, Overwrite a marked range onto a regular sequence, park playhead inside the new clip, play, verify: audio audible, waveform renders, decoder output bit-identical to direct file read (FR-025).

### Agent file update
Run `.specify/scripts/bash/update-agent-context.sh claude` after Phase 1 to keep `CLAUDE.md` current.

## Phase 2: Task Planning Approach

Generated by `/tasks` from this plan + the contracts/. Expected shape:

**Ordering Strategy**:
1. Schema + invariant triggers (foundation; failing tests for invariant violations land first).
2. Subframe math primitive (pure module; unit tests first).
3. `clip_position` accessor module (consumes math primitive; tests first).
4. Resolver update (`pick_master_leaf` consumes subframe via clip_position; FR-008 test first).
5. Schema-bump hard-error open path (Clarification Q2 test first).
6. Conform/settings commands (per-command test first, then implementation).
7. Importer updates (per-importer test first).
8. Edit-command updates (per-command subframe-preservation test first).
9. Legacy accessor removal + grep-guard chokepoint test.
10. End-to-end acceptance + order-independence + multi-rate-audio integration tests.

**Parallelism**: subframe_math, clip_position, and the conform commands can be implemented in parallel after schema lands. Edit commands can be done in parallel. Importers can be done in parallel.

**Estimated Output**: ~30-35 numbered tasks in `tasks.md`.

## Complexity Tracking

No constitutional violations. The design adds two new modules (`subframe_math`, `clip_position`) and three new commands — all natural deliverables for the requirement, none of which introduce architectural complexity beyond what the spec demands. The DRY accessor is a *simplification* (single chokepoint replaces scattered field accesses) and the schema-level invariants *reduce* runtime check complexity (Constitution V.21 statically-verifiable).

---
*Based on Constitution v2.0.0*
