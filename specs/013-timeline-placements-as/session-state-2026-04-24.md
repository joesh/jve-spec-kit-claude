# 013 session state — 2026-04-24 (second unsupervised block, "go")

## Commits this session block (resumed from 21116808)

| Commit | Scope |
|---|---|
| `70ddc2ec` | T015 partial + T017 partial: model layer — Phase 3.2 all green |
| `7fc4325c` | T030: `Sequence:pick_in_range` + Phase 3.3.a all green |

Combined with prior block (11 commits): **13 commits total for 013**.

## What's green

**25/25 tests green** across Phase 3.1 + 3.2 + 3.3.a:
- 7 schema tests
- 6 model-layer INV tests (INV-1, INV-2, INV-3 cycle, INV-4, INV-8, track-delete repoint)
- 12 resolver contract tests (CT-R1..R11 + T029 dangling layer)

## Code shipped this block

`src/lua/models/sequence.lua`:
- `Sequence.create` now requires explicit `opts.kind ∈ {'master','nested'}` and `opts.audio_rate` (rule 2.13 — no 48000 default, no 'timeline' default).
- `Sequence.save` writes V9 columns: `default_video_layer_track_id`, `video_start_tc_frame`, `audio_start_tc_samples`, `fps_mismatch_policy`.
- NEW `Sequence.find(id)` → row table; `Sequence.update(id, fields)` with INV-8 post-condition; `Sequence.assert_inv8(id)` with actionable error (names seq id, actual kind, actual default — rule 1.14).
- NEW `Sequence:pick_in_range(seq_id, start, end, context)` — the resolver. 14 named helpers: is_media_online, fetch_kind, fetch_default_video_layer, assert_layer_ref_valid, fetch_master_channel_state, fetch_clip_channel_override, db_to_linear, list_media_refs, list_clips_overlapping, build_provenance, pick_master_leaf, pick_nested, clamp_entries_to_clip_window, pick_seq_range.

`src/lua/models/clip.lua`:
- `Clip.create` overloaded: first-arg-is-table dispatches to new V13 path; positional path untouched (legacy callers keep working).
- NEW `Clip._create_v13_row(fields)` — INV-2 pre-flight (loud message with clip, owner, kind), INV-4 via assert_window_in_bounds, rule 2.13 required-fields.
- NEW `Clip.update(id, fields)` with INV-4 post-condition.

`src/lua/models/track.lua`:
- NEW `Track.delete(id)` with INV-6 logic: repoint default if other V tracks live, clear default if no refs + no other V, refuse if no other V + live refs.

`tests/test_env.lua`:
- NEW `M.touch_media_fixtures()` — touches every `media.file_path` in current DB so resolver reachability checks see synthetic test rows as online.

## Key design decisions baked in

- **Channel gain composition (CT-R6)**: per-clip override REPLACES the master's channel gain. Implementation divides out the master-state factor before multiplying in the override, so the override is the channel gain of record.
- **fps_mismatch_policy is structural**: `clips.duration_frames` is what the resolver returns. Insert is responsible for the round-under-policy math; resolver just reads.
- **Legacy APIs preserved**: `Clip.create(positional, ...)`, `Sequence.create(name, pid, fr, w, h, opts)` both still work. New table-form APIs alongside. Old ones will be removed alongside the bulk test migration in a future session.

## What's still blocked / pending

- **T031 wrapper retrofit** — class-form `Sequence:get_video_in_range(seq_id, ...)` + `get_audio_in_range(seq_id, ...)`. Existing instance-form wrappers still live (old signature); test_resolve_wrapper_shape fails against them pending T031.
- **T015 / T017 full narrow** — the positional `Clip.create` and `Sequence.create` still read/write old-shape assumptions in their legacy branches. Full removal requires migrating 45+ callers.
- **Phases 3.4 onward** — all commands (Insert, Overwrite, Trim, Slip, Slide, Roll, Ripple, Split, Blade, Nest, Unnest, all overrides), all importers, renderer, inspector, integration.
- **T108a banned-identifier regression test** — not yet written.
- **Bulk test migration** — ~120 boilerplate tests need sed-style updates.
- **REWRITE candidates** — 8 test files identified in existing-test-triage.md (`test_ensure_masterclip*`, `test_clip_mutator`, etc.).
- **Full make is broken** — existing callers of `Clip.create` etc. that pass positional args with old-shape opts will still fail under V9 because they expect `clip_kind` etc. to round-trip. The targeted tests above all pass; the full suite does not.

## Nothing to undo

- `pre-013-refactor` tag still at `c64fca24` — tagging point for pre-013 builds.
- Schema V9 destructive.
- 5 test files DELETE'd in an earlier commit.
- Legacy `Clip.create` and `Sequence.create` positional forms still work for their existing callers.

## Proposed next session

1. **T031 wrapper retrofit** — replace instance-method `get_video_in_range` / `get_audio_in_range` with class-form that accepts `seq_id`. Fix all callers (playback_engine etc). Turns test_resolve_wrapper_shape green.
2. **Bulk test migration script or agent-driven pass** — identify the boilerplate-only tests + transform mechanically. Then the 8 REWRITE outliers by hand.
3. **T108a banned-identifier regression** — standing guard.
4. **Phase 3.4 rewired commands** — Insert is the long pole. Once Insert lands with the two-policy path, half the integration tests become writable.

Tree head: `7fc4325c` on `013-timeline-placements-as`. Tag: `pre-013-refactor` at `c64fca24`.
