# Tasks: Uniform Clip Source Timebase with Canonical-Clock Sub-Frame Primitives

**Branch**: `018-uniform-clip-source`
**Generated from**: plan.md, research.md, data-model.md, contracts/, quickstart.md
**Format**: `[ID] [P?] Description (FR refs)` — `[P]` = parallelizable (different files, no shared dependencies).
**Convention**: ALL test tasks land before their implementation tasks (Constitution III TDD). Each test starts as a failing test against an unimplemented module; implementation flips it green.

## Phase 3.1: Schema + foundation (sequential — single schema.sql + the open-error path)

- [ ] **T001** Bump `schema_version` from 10 → 11 in `src/lua/schema.sql`. Update header comment to reference 018.
- [ ] **T002** Add `clips.source_in_subframe INTEGER` and `clips.source_out_subframe INTEGER` columns to the `clips` CREATE TABLE in `src/lua/schema.sql`. Both nullable at column level; presence-by-kind enforced by INV-3 trigger (T005).
- [ ] **T003** Add `media_refs.audio_sample_rate INTEGER` column to the `media_refs` CREATE TABLE in `src/lua/schema.sql`. Nullable for video-only media_refs.
- [ ] **T004** [P] Write failing test `tests/test_schema_version_bump_hard_error.lua` — opens a synthetic V10 `.jvp`, asserts `Project.open` raises the spec'd schema-mismatch error message naming "re-import from original source". (Clarification Q2.)
- [ ] **T005** Add invariant triggers INV-3, INV-4, INV-5, INV-6, INV-7 in `src/lua/schema.sql` per `data-model.md` § "Invariant triggers". Each trigger raises `ABORT` with the documented invariant-id message.
- [ ] **T006** [P] Write failing test `tests/test_subframe_invariants.lua` covering every assert path in `data-model.md`: INV-3 video+non-NULL-sub, INV-3 audio+NULL-sub, INV-4 sub<0, INV-4 sub>=tpf, INV-5 direct UPDATE outside ConformSequence, INV-6 direct settings-update outside SetProjectMasterClock, INV-7 master with non-NULL audio_sample_rate, V11 `sequences.audio_sample_rate` write attempted on `kind='master'`.
- [ ] **T007** Modify `src/lua/core/database.lua` schema-version check to use the 018 actionable error message. Surfaces through existing error dialog. Add `default_fps = {num=24, den=1}` and `master_clock_hz = 192000` to the projects.settings JSON written at project creation.
- [ ] **T008** Run T004 + T006 — both should now PASS (schema + triggers + open-error landed).

## Phase 3.2: Pure math primitive (`core/subframe_math.lua`)

- [ ] **T009** [P] Write failing test `tests/test_subframe_math.lua` per `contracts/subframe_math.md` § "Tests" — full combinatorial grid over (master_clock_hz × source_seq.fps × file_rate × subframe × samples), pack/unpack round-trip, samples↔ticks round-trip (exact for divisors, ≤0.5 for non-divisors), every invalid-input assertion fires.
- [ ] **T010** Implement `src/lua/core/subframe_math.lua` per `contracts/subframe_math.md` § "Public API". Pure Lua, zero dependencies. Private `round_half_away_from_zero` helper. Each function ≤10 LOC body (Constitution 2.5).
- [ ] **T011** Run T009 — should PASS.

## Phase 3.3: DRY accessor (`core/clip_position.lua`)

- [ ] **T012** [P] Write failing test `tests/test_clip_position_accessor_chokepoint.lua` — static scan of `src/lua/` for forbidden patterns (`clip.source_in_frame =`, `clip.source_out_frame =`, `clip.source_in_subframe =`, `clip.source_out_subframe =`, raw `UPDATE clips SET source_*`). Allowed only inside `src/lua/core/clip_position.lua` and `src/lua/core/database.lua`. (FR-009a.)
- [ ] **T013** [P] Write failing test `tests/test_clip_subframe_persistence.lua` (FR-020) — write audio clip via `clip_position.write_audio_source` with non-zero subframes, save project, reload, assert exact round-trip.
- [ ] **T014** Implement `src/lua/core/clip_position.lua` per `contracts/clip_position.md` § "Public API". Reads, writes, sample↔(frame, subframe) helpers, frame-aligned convenience. Every function asserts per contract.
- [ ] **T015** Run T013 — should PASS. T012 will FAIL until call-site migration (later phases) — leave as known-failing for now, document in test comment.

## Phase 3.4: Model + resolver integration

- [ ] **T016** [P] Write failing test `tests/test_resolver_subframe.lua` (FR-021) — synthesize clip with subframe=N at 192000 ticks/sec against media_ref at 48000 Hz file rate, assert resolver returns file_sample offset of exactly `N * 48000 / 192000` vs the same clip with subframe=0. Test both divisor (48k) and non-divisor (44.1k) file rates with the latter asserting ≤0.5 sample bound.
- [ ] **T017** Modify `src/lua/models/sequence.lua` `resolve_master_leaf` (lines 2202-2270) to consume subframes through `clip_position.frame_subframe_to_samples` (which wraps `subframe_math.ticks_to_samples`). Reuse existing `round_int` since it matches FR-008 rounding (Constitution 2.5 — keep functions algorithm-style).
- [ ] **T018** Modify `src/lua/core/database.lua` `load_clips` to hydrate the new subframe columns. Tripwire assert on read: audio clip must have non-NULL subframes; video must have NULL. (Defense-in-depth mirrors INV-3.)
- [ ] **T019** Modify `src/lua/models/clip.lua` and `src/lua/core/clip_mutator.lua` so any clip-row construction routes through `clip_position` (no direct field writes). Update INSERT statements in `database.lua` to include the new columns.
- [ ] **T020** Run T016 — should PASS.

## Phase 3.5: Importers

- [ ] **T021** [P] Write failing test `tests/test_drp_importer_subframe.lua` (FR-022) — synthetic DRP with known sample-precise audio start, run importer, assert stored `(frame, subframe)` round-trips through math primitive to within one project-clock tick of the original sample value.
- [ ] **T022** Modify `src/lua/importers/drp_importer.lua` to write audio clip source positions via `clip_position.samples_to_frame_subframe` + `write_audio_source`. New masters' fps initialized from project default (FR-032) — NEVER from first-imported media's native rate. Populate `media_refs.audio_sample_rate` from the underlying media row.
- [ ] **T023** Modify `src/lua/importers/fcp7_xml_importer.lua` — verify frame-aligned values get sub-frame defaults of zero via `clip_position.write_audio_source_frame_aligned`. Master fps from project default (FR-032).
- [ ] **T024** Add TODO comment + entry in `src/lua/importers/prproj_importer.lua` (or wherever the prproj path lives) noting it's out of scope per FR-012; behavior left as-is until follow-up spec.
- [ ] **T025** Run T021 — should PASS.

## Phase 3.6: Edit commands (parallelizable per-command)

Each command's modification preserves subframes through its math; new clips get subframe=0 via `write_audio_source_frame_aligned` (FR-013).

- [ ] **T026** [P] Write failing test `tests/test_edit_command_subframe_preservation.lua` (FR-023) — for at least three representative mutating ops (slip, roll, split), build a clip with subframe=N, apply op, verify subframe unchanged. Repeat for undo and redo.
- [ ] **T027** [P] Modify `src/lua/core/commands/insert.lua` — new audio clips get subframe=0 via accessor.
- [ ] **T028** [P] Modify `src/lua/core/commands/overwrite.lua` — same.
- [ ] **T029** [P] Modify `src/lua/core/commands/slip.lua` — frame delta does NOT touch subframe; preserve through.
- [ ] **T030** [P] Modify `src/lua/core/commands/roll.lua` — same.
- [ ] **T031** [P] Modify `src/lua/core/commands/trim_head.lua` / `trim_tail.lua` — same.
- [ ] **T032** [P] Modify `src/lua/core/commands/split.lua` — new pair-of-clips both inherit existing subframe at the split point (or 0 if the split is frame-aligned).
- [ ] **T033** [P] Modify `src/lua/core/commands/batch_ripple_edit.lua` — same.
- [ ] **T034** Modify `src/lua/core/commands/_place_shared.lua` — subframe-aware mark conversion. The current frame-only path passes through; once user-facing sample-precise marks land (future spec) the path will populate non-zero subframes.
- [ ] **T035** Run T026 — should PASS for all three exercised commands.

## Phase 3.7: Legacy accessor removal (FR-016, FR-017)

- [ ] **T036** Identify every consumer of `Sequence.get_effective_audio_in`, `Sequence.get_effective_audio_out`, `Sequence.video_frame_to_audio_sample`. (Likely: `core/gather_context_for_command.lua` `resolve_clip_marks` and possibly UI mark display.)
- [ ] **T037** Migrate each consumer to read via `clip_position.read_audio_source` (or, for marks at the frame level, the frame-only accessor). No silent default-to-zero; every read explicitly handles audio-vs-video.
- [ ] **T038** Delete the legacy accessor functions from `src/lua/models/sequence.lua`.
- [ ] **T039** Run T012 (chokepoint test) — should now PASS (no remaining direct field access outside the allowed modules).

## Phase 3.8: Conform / settings commands

- [ ] **T040** [P] Write failing test `tests/test_set_project_default_fps.lua` (FR-036a) per `contracts/set_project_default_fps.md` § "Tests". Includes invariant test (zero fps_numerator → assert).
- [ ] **T041** [P] Write failing test `tests/test_set_project_master_clock.lua` (FR-036b) per `contracts/set_project_master_clock.md` § "Tests". Includes INV-6 direct-update enforcement.
- [ ] **T042** [P] Write failing test `tests/test_conform_sequence.lua` (FR-035) per `contracts/conform_sequence.md` § "Tests". Covers kind='master', kind='sequence', atomic rollback, INV-5 enforcement.
- [ ] **T043** [P] Implement `src/lua/core/commands/set_project_default_fps.lua` per contract. Single-row UPDATE; no cascade; undoable.
- [ ] **T044** [P] Implement `src/lua/core/commands/set_project_master_clock.lua` per contract. Transactional; temp-table flag for INV-6; per-clip subframe rescale; undoable.
- [ ] **T045** [P] Implement `src/lua/core/commands/conform_sequence.lua` per contract. Transactional; temp-table flag for INV-5; per-kind internal rewrite + outer-clip rewrite; undoable.
- [ ] **T046** Register all three commands with `command_manager` (canonical command registration path).
- [ ] **T047** Run T040, T041, T042 — all should PASS.

## Phase 3.9: Acceptance + cross-cutting tests

- [ ] **T048** [P] DEFERRED — requires `--test` mode (C++ decode + peak cache bindings). FR-025 audibility is already pinned by `tests/test_018_fr025_overwrite_audio_audible.lua` (resolver entries point at correct file + sample range); bit-identity vs raw file read needs a separate `--test`-mode harness, tracked outside this feature.
- [x] **T049** [P] `tests/test_master_order_independence.lua` (FR-033) — GREEN. Two masters same media opposite insertion order; resolver bit-identical via file_sig + explicit media_id check.
- [x] **T050** [P] `tests/test_multi_rate_audio_master.lua` (FR-034) — GREEN. V+A48k+A96k master; native rates preserved, no silent resample collapse.
- [x] **T051** Ran T049, T050 → both green. T048 deferred.

## Phase 3.10: Documentation + final cleanup

- [ ] **T052** Update `src/lua/models/sequence.lua` and related model files: remove or revise any wording endorsing pre-018 conventions per FR-018 (dual-unit accessors, order-dependent fps, master.audio_sample_rate, "audio-only master uses fps=sample_rate", direct fps mutation). Per Constitution 2.16 — no half-finished cleanup.
- [ ] **T053** Run full `make -j4` — luacheck zero warnings, all Lua tests pass, all C++ tests pass.
- [ ] **T054** Manual smoke (per `quickstart.md` § "Acceptance checklist") — open editor, import DRP, F10, play, hear audio. Verify waveform renders. Verify ConformSequence + SetProjectMasterClock + SetProjectDefaultFps via test scripts (no UI per Clarification Q1).

## Dependency graph

```
T001-T003 (schema columns) ─┬─ T005 (triggers)
                            ├─ T007 (db open-error path)
                            └─ T002 enables T013, T014, T018
T004 ── (before) ── T007 ── T008
T005 ── (before) ── T006 ── T008

T009 ── T010 ── T011                   (math primitive)

T010 + T002 ── T012, T013 ── T014 ── T015 (clip_position; chokepoint defer to T039)

T010 + T014 + T002 ── T016 ── T017, T018, T019 ── T020 (resolver + load + mutator)

T014 + T002 ── T021 ── T022, T023 ── T025 (importers)
T024 (TODO comment) parallel

T014 + T002 ── T026 ── T027..T034 ── T035 (edit commands)

T014 ── T036 ── T037 ── T038 ── T039 (legacy removal; flips T012 green)

T005 + T014 ── T040, T041, T042 ── T043, T044, T045 ── T046 ── T047 (conform/settings)

T010 + T014 + T017 + T022 + T046 ── T048, T049, T050 ── T051 (acceptance)

ALL implementation ── T052 ── T053 ── T054 (final)
```

## Parallel execution clusters

| Cluster | Tasks | Why parallel |
|---|---|---|
| Schema-foundation tests | T004, T006 | Different test files; independent failures. |
| Math primitive tests | T009 | Single file; sequential within. |
| Accessor + persistence tests | T012, T013 | Different test files. |
| Importer tests | T021 | Single file. |
| Edit command implementations | T027–T033 | Each command in its own file; no shared mutation. |
| Conform/settings tests | T040, T041, T042 | Different test files. |
| Conform/settings implementations | T043, T044, T045 | Different files; no shared state until T046. |
| Acceptance tests | T048, T049, T050 | Different test files. |

## Notes

- Every implementation task is gated by a failing test (Constitution III TDD).
- The chokepoint test (T012) is written early as a forcing function but legitimately fails until T039 lands. Document this in the test header so it's not mistaken for a real regression.
- `--test` mode required for T048 (full C++ bindings — decoder, peak cache).
- No UI work in this feature (Clarification Q1). Manual smoke (T054) drives commands via script.
- Old `.jvp` files: regenerate per `feedback_schema_bump_freely`. No migration code.

---

*Tasks ready for execution. Total: 54 numbered tasks across 10 phases.*
