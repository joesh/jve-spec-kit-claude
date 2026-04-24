# 013 session state — 2026-04-24 (unsupervised block)

## Commits landed this session (11)

| Commit | Scope |
|---|---|
| `80b91587` | sibling's relink + peak self-heal fix |
| `c64fca24` | sibling's regression tests for that fix |
| `58420623` | 013 spec-kit artifacts (plan/data-model/contracts/tasks/triage) |
| `ce1b8b0a` | T001–T008 — V9 schema + 7 schema tests |
| `bb9ecc1c` | T009–T013d — 6 model-layer failing tests |
| `53f75983` | T014 + T016 — media_ref.lua + cycle.lua impls |
| `b007cc2c` | T007a DELETE — 5 tests removed (rescale, DeleteMasterClip, etc.) |
| `43b2c6d4` | T018–T027 — 6 resolver contract tests |
| `7119018a` | T022/T025/T029/T029b — 4 more resolver tests (incl. fps-mismatch both paths) |
| `7f00eca1` | T020/T023/T028 — final Phase 3.3.a resolver tests |
| (this doc) | session summary |

## What's green

All tests that should be passing are passing:
- 7 schema tests (T001–T007)
- 2 model impls green against their tests (T014, T016)

All TDD-gated tests are failing for the right reason (module missing or signature-mismatch):
- 6 Phase 3.2 model tests
- 13 Phase 3.3.a resolver tests

## Key contract changes negotiated mid-session

1. **`clips.fps_mismatch_policy` is NOT NULL, structural at Insert time** — the big discovery. Because `duration_frames` is in owner timebase and `source_in/out` is in nested timebase, Insert/Overwrite must know the policy to compute duration. Flipping policy later (SetFpsMismatchPolicy, clip scope) is a structural mutation that re-computes duration + ripples downstream. Linked V+A clips flip together. Rounding policy: round-to-nearest under `resample` (accept sub-frame drift).
2. **Policy settable at project + sequence levels** (both stored), plus optional Insert arg to override per-drop.
3. **fps_numerator/fps_denominator dropped from clips + media_refs** — dereferences to `nested_sequence_id` / `media_id`. Pure denormalization removed.
4. **`owner_sequence_id`** kept (existing convention); `ensure_master` rename (was `ensure_masterclip`).
5. **Sibling's relink fix landed first** as a clean two-commit unit before any 013 schema work — branch was clean for 013 to proceed.

## What's blocked on T015 / T017 (big rewrites)

These are the next atomic unit but I halted before them because they cascade:

- **T015 narrow `src/lua/models/clip.lua`** (960 LOC, ~50 caller files). Drop old-schema columns; add `nested_sequence_id`, `master_layer_track_id`, `fps_mismatch_policy`; INV-2 assert; INV-4 assert.
- **T017 narrow `src/lua/models/sequence.lua`** (1526 LOC, wide caller surface). Narrow kind; rename `ensure_masterclip` → `ensure_master`; INV-8 enforcement; new column accessors; `resolve_in_range` orchestrator helpers go in here per T030 decomposition.

Both must land together atomically with the test migration (Option B bulk-migrate script for ~120 tests + hand-REWRITEs for the 8 outliers identified in `existing-test-triage.md`) — otherwise the tree is broken for everyone.

## What's deferred (acknowledged in commits)

- **T013a** INV-5 channel-index bounds at resolve time — needs resolver.
- **T013c** INV-7 single link group per clip — needs link commands (Phase 3.4).
- **T029a** INV-5 at resolve time — same pattern as T013a, also deferred.
- **T030** the actual `resolve_in_range` implementation. Orchestrator + 11 helpers per T030 task text.
- **T031** `get_video_in_range`/`get_audio_in_range` thin-wrapper retrofit.
- **T092b** C++ TMB shape audit — may surface real C++ edits if the wrapper doesn't preserve shape.
- Phases 3.4 through 3.12.

## Nothing to undo

- `CLAUDE.md` has 013 tech-stack lines (not mine-only — came through `/plan`). Committed in the spec-kit commit.
- Schema.sql is V9 destructive. Old .jvp files will not open. Per FR-018.
- 5 tests were git-rm'd. Listed in the triage doc; commit message explains each.
- `existing-test-triage.md` is the living migration plan for the other ~235 test files.

## Proposed next session

1. Gate: confirm the contract changes above (especially fps_mismatch_policy structural) are what you want.
2. Pick an atomic landing strategy for T015 + T017 + helpers + bulk test migration:
   - Option A: one giant commit. Breaks nothing visibly because it all lands at once.
   - Option B: sequential small commits with `make` broken in between. Faster to review but leaves the tree broken.
   - Option C: long-running feature branch off `013-timeline-placements-as`, merge when all integration tests green.
3. Decide test migration strategy: auto-script (complex regex over Lua INSERT statements) vs. agent-driven (Claude goes file-by-file with a checklist).
4. Drive T030 (resolver impl) as it's the long pole — 11 helpers + the orchestrator. Then all 13 Phase 3.3.a tests go green simultaneously.

## Files changed this session

### New (committed)
```
specs/013-timeline-placements-as/plan.md
specs/013-timeline-placements-as/research.md
specs/013-timeline-placements-as/data-model.md
specs/013-timeline-placements-as/quickstart.md
specs/013-timeline-placements-as/tasks.md
specs/013-timeline-placements-as/existing-test-triage.md
specs/013-timeline-placements-as/contracts/commands.md
specs/013-timeline-placements-as/contracts/renderer.md
specs/013-timeline-placements-as/contracts/resolver.md
src/lua/models/media_ref.lua
src/lua/models/cycle.lua
tests/test_schema_sequences_kind_check.lua
tests/test_schema_media_refs.lua
tests/test_schema_clips_shape.lua
tests/test_schema_media_refs_channel_state.lua
tests/test_schema_clip_channel_override.lua
tests/test_schema_projects_fps_policy.lua
tests/test_schema_sequences_new_columns.lua
tests/test_media_ref_inv1.lua
tests/test_clip_inv2.lua
tests/test_cycle_detection.lua
tests/test_clip_inv4_window.lua
tests/test_sequence_inv8_default_layer.lua
tests/test_master_track_delete_default_repoint.lua
tests/test_resolve_master_leaf.lua
tests/test_resolve_nested_one_level.lua
tests/test_resolve_layer_override.lua
tests/test_resolve_cycle_assert.lua
tests/test_resolve_offline_leaf.lua
tests/test_resolve_export_parity.lua
tests/test_resolve_channel_disable.lua
tests/test_resolve_fps_mismatch.lua
tests/test_resolve_dangling_layer_assert.lua
tests/test_resolve_wrapper_shape.lua
tests/test_resolve_nested_deep.lua
tests/test_resolve_deterministic.lua
tests/test_resolve_channel_gain.lua
```

### Modified (committed)
```
CLAUDE.md                     (013 tech stack lines)
src/lua/schema.sql            (V8 → V9)
specs/013-timeline-placements-as/spec.md  (audit-pass updates)
```

### Deleted (committed)
```
tests/test_insert_rescales_master_clip_to_sequence_timebase.lua
tests/test_overwrite_rescales_master_clip_to_sequence_timebase.lua
tests/test_delete_master_clip.lua
tests/test_duplicate_master_clip.lua
tests/test_sequence_masterclip_methods.lua
```

### Sibling's work (committed — not mine)
```
src/editor_media_platform/...  (relink + peak fixes)
src/lua/core/commands/relink_*.lua
src/lua/core/media/peak_cache.lua
src/lua/core/media_probe_cache.lua
src/lua/core/media_relinker.lua
src/lua/core/relink_planner.lua
src/lua/models/media.lua
src/lua/ui/timeline/view/timeline_view_renderer.lua
tests/integration/test_peak_cache_mtime_fractional.lua
tests/integration/test_peak_cache_coverage_regen.lua
tests/integration/test_relink_tc_resync.lua
```

## Unresolved for Joe

1. **fps_mismatch_policy on clips is NOT NULL** — confirm this is the contract you want (it's now in schema + data-model.md + commands.md + the two committed resolver tests for it).
2. **Rounding rule under resample** — round-to-nearest. Accepted as-is; flag if you want a different rule.
3. **ensure_master rename** — confirmed by you.
4. **owner_sequence_id vs owning_sequence_id** — you picked owner_sequence_id.
5. **DELETE 5 tests** — you picked DELETE; committed.
6. **Next session plan** — the A/B/C option question for atomic landing, above.
