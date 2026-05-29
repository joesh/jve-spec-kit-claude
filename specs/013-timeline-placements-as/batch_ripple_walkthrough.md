# BatchRippleEdit V13 migration — pipeline walkthrough

Reading session output. Goal: produce enough understanding to plan the V13
migration of `core/commands/batch_ripple_edit.lua` (2309 LOC) without
losing behavior.

## File layout

- `core/commands/batch_ripple_edit.lua` — registration shim + ~80 internal
  helper functions. The executor at line 2074 builds a context via
  `batch_context.create` and runs the pipeline via `batch_pipeline.run`.
- `core/ripple/batch/pipeline.lua` — 12-stage pipeline orchestrator (29 LOC).
- `core/ripple/batch/context.lua` — `ctx` shape + edge_info normalization
  (65 LOC).
- `core/ripple/batch/prepare.lua` — sequence rate + delta resolution (55 LOC).
- `core/ripple/{edge_info,track_index,undo_hydrator}.lua` — supporting modules.
- `core/gap_lifecycle.lua` — synthesizes in-memory gap clips (sets
  `clip_kind = "gap"` on the gap object). Gaps live on `timeline_state`,
  NOT in the DB.

## Pipeline (12 stages, in execution order)

1. **`build_clip_cache(ctx)`** — pulls all clips from `timeline_state`
   (NOT the DB). `timeline_state.get_track_clip_index(track_id)` returns
   real clips + synthesized gap clips for that track. Outputs:
   `ctx.all_clips`, `ctx.clip_lookup` (id→clip), `ctx.clip_track_lookup`
   (id→track_id), `ctx.track_clip_map` (track_id→[clips]).
2. **`prime_neighbor_bounds_cache(ctx)`** — precomputes left/right
   neighbor bounds per clip for O(1) constraint checks. Delegates to
   `ripple_track.build_neighbor_bounds_cache`.
3. **`inject_implicit_gap_edges(ctx)`** — for each ripple edge, finds the
   gap clip on OTHER tracks at the same boundary frame and ADDS it as an
   implicit edge in `ctx.edge_infos`. If no real gap exists at that
   frame on another track, synthesizes a zero-length implicit gap. This
   is what makes single-track ripple propagate across all tracks without
   the user explicitly selecting linked edges.
4. **`assign_edge_tracks(ctx)`** — fills in `edge.track_id` on any edge
   that arrived without one (UI sometimes provides clip_id only).
5. **`determine_lead_edge(ctx)`** — picks the "primary" edge (the one
   the user is dragging). Used downstream to compute drag direction and
   global delta sign.
6. **`analyze_selection(ctx)`** — classifies each edge as `roll` or
   `ripple` based on `trim_type` and presence of an adjacent partner edge.
7. **`compute_constraints(ctx)`** — for each edge, computes min/max
   allowed delta based on:
   - **media boundary** (V8 — `clip.media_id` lookup; see below)
   - neighbor bounds (gap minimum duration; cannot collapse a gap below
     zero or pull a clip past its neighbor)
   - duration floor (cannot collapse a clip below 1 frame)
   - roll constraints (both sides must remain valid)
   Aggregates per-edge constraints into `ctx.global_min_frames` /
   `ctx.global_max_frames`. Tracks which edge keys are at the limit
   (`global_min_edge_keys`, `global_max_edge_keys`) so the UI can
   highlight blockers.
8. **`process_edge_trims(ctx)`** — for each edge, applies the (clamped)
   delta. Mutates the working `ctx.modified_clips[clip_id]` entry.
   Tracks per-track ripple anchors (`ctx.track_shift_seeds`) — the frame
   from which downstream clips will shift.
9. **`compute_downstream_shifts(ctx)`** — based on ripple anchors per
   track, computes how much each downstream clip shifts. Handles
   cross-track propagation. Returns `false, adjusted_frames` if the
   computed shift would create an overlap → triggers retry.
10. **`retry_with_adjusted_delta(ctx, adjusted_frames)`** — re-enters the
    pipeline with a clamped delta and saves the blocker edge keys to
    `__shift_blocker_keys` so a subsequent retry doesn't lose them. UI
    relies on these keys to highlight which edges hit the wall.
11. **`build_planned_mutations(ctx)`** — converts `ctx.modified_clips`
    and `ctx.bulk_shift_mutations` into a flat list of
    `{type = "insert"/"update"/"delete"/"bulk_shift", ...}`. Sorts by
    timeline position so writes don't trigger transient overlap on the
    video-overlap trigger.
12. **`finalize_execution(ctx)`** — calls
    `command_helper.apply_mutations(db, ctx.planned_mutations)` to write
    to the DB, persists undo state, emits UI sync mutations.

## V8-column touches: triage

`grep -n "media_id\|clip_kind\|master_clip_id\|\.offline"` returned 25
hits. Categorized:

### (A) Valid in-memory gap detection — KEEP AS-IS

16 of the 25 hits are `clip_kind == "gap"` or `clip_kind ~= "gap"` reads
at lines 347, 389, 407, 512, 531, 788, 824, 831, 1136, 1254, 1306, 1387,
1562, 1667, 1781, 1940. These check the in-memory gap-clip shape produced
by `gap_lifecycle.lua:39`, which still sets `clip_kind = "gap"` even
under V13 (gap_lifecycle is in-memory and unaffected by schema migration).

These reads are intentional and correct under V13. Do NOT remove them.

### (B) Needs V13 substitute — REWRITE

- **`fetch_media_for_clip` (lines 290–300):** loads media metadata via
  `models.media.load(clip.media_id, db)` for media-boundary clamping.
  V13 substitute: walk `clip.nested_sequence_id` to its native duration.
  - If `Sequence.find(clip.nested_sequence_id).kind == 'master'`, the
    "media boundary" is `Sequence.native_duration_for_medium(nested_id, kind)`
    where `kind ∈ {'VIDEO', 'AUDIO'}` based on the clip's track type.
  - If kind is `'nested'`, the boundary is the nested sequence's
    effective duration (`MAX(timeline_start + duration)` across its
    contained clips).
  - This is what `INV-4` already enforces post-write via
    `Clip.update_bounds → assert_window_in_bounds`. Pre-clamping is the
    UX-feedback variant of the same constraint.

- **`load_clip_for_edit` (lines 698–718):** builds a working clip
  object. Drops `media_id`, `master_clip_id`, `clip_kind` from V8.
  V13 working-clip shape should carry:
  - `nested_sequence_id` (replaces `media_id`)
  - `master_layer_track_id` (new V13 field — preserves layer override)
  - `fps_mismatch_policy` (new V13 field — frozen at Insert)
  - keep `clip_kind` for in-memory gap compatibility (read from base;
    real clips will have `nil`, gaps will have `"gap"`)
  - DROP `master_clip_id` (no V13 equivalent; the "is this a master?"
    question is answered by walking `nested_sequence_id` and checking
    `sequences.kind`)

### (C) Comment only — TRIVIAL

Line 30: a `--` comment referencing `clip_kind ~= "gap"` semantics.
Update wording to reflect V13 if the comment changes meaning.

## Cascade dependencies (NOT YET V13-clean)

`batch_ripple_edit` reads/writes through several helpers that ARE NOT
yet V13-migrated:

- **`command_helper.lua`** — 23 V8-column touches. Used here for:
  - `capture_clip_state(clip)` (line 519, reads `clip_kind`,
    `master_clip_id`, `media_id`, `offline`) — used by undo.
  - `apply_mutations(db, planned_mutations)` (final write step).
  - `clip_update_payload` / `add_*_mutation` — used by stages 1–11.
    (`clip_insert_payload` was retired 2026-05-29: insert entries now
    re-read the canonical DB row via `_mutation_entry.build_insert_entry`
    → `database.load_clip_entry`, the same builder `db.load_clips` uses.)
  Migrating batch_ripple_edit alone won't work cleanly; command_helper
  must migrate alongside or first.
- **`clip_mutator.lua`** — V8-shape clip operations. Need to audit.

`timeline_state.lua` has 0 V8 touches and is already shape-agnostic.

## Open questions for next session

1. **Pre-clamp UX vs hard INV-4 throw.** V13 INV-4 throws on overflow.
   Should `compute_constraints` keep the pre-clamp + blocker-keys path
   (richer UI feedback) or simplify to "let INV-4 throw, surface error
   to UI"? Pre-clamp is more code but better UX.
2. **`master_clip_id` in undo state.** `command_helper.capture_clip_state`
   stores it. If undo restores a clip via that state, the V8 column is
   missing in V13. Need a separate V13 undo-capture path.
3. **`clip_mutator.lua` scope.** Its 27 V8 touches (estimated) cascade
   from batch_ripple_edit's `apply_mutations` flow. Migration order
   matters: command_helper → clip_mutator → batch_ripple_edit.
4. **Media-boundary clamping for nested→nested clips.** When a clip
   references a nested sequence (not a master), the "media boundary"
   is the nested's effective duration, which can change as the user
   edits the nested. Should the clamp re-resolve every trim, or cache?

## Recommended migration order

1. **command_helper.lua** — ~23 V8 touches; foundation for many
   commands. Add V13 variants of `capture_clip_state` (carrying
   `nested_sequence_id`, `master_layer_track_id`, `fps_mismatch_policy`)
   and `apply_mutations`/`clip_*_payload` helpers.
2. **clip_mutator.lua** — depends on (1); update mutation-generation
   to emit V13-shape rows.
3. **batch_ripple_edit.lua** — surgical replacement of:
   - `fetch_media_for_clip` — walk `nested_sequence_id`
   - `load_clip_for_edit` — drop `master_clip_id`, replace `media_id`
     with `nested_sequence_id`, add `master_layer_track_id` +
     `fps_mismatch_policy`
   - 16 `clip_kind == "gap"` reads — leave alone
4. **`ripple_edit.lua`** — already agreed: delete; both call sites
   redirect to `BatchRippleEdit` with single-element `edge_infos`.

## Minimum-viable contract test for V13 BatchRippleEdit

Once (1)–(3) above land, the contract test should cover:

1. **Single-edge ripple-trim head** (in edge): `clip.duration` shrinks by
   N, `source_in` advances by `owner_delta_to_source(policy, N, ...)`,
   `timeline_start` unchanged, downstream on same track shifts by `-N`.
2. **Single-edge ripple-trim tail** (out edge): `clip.duration` grows by
   N, `source_out` advances by source delta, downstream shifts by `+N`.
3. **Linked V+A pair**: a ripple-trim on V's edge ALSO trims A's matching
   edge (per FR-003 link-as-unit), each track's downstream shifts
   independently.
4. **Implicit gap-edge propagation**: ripple-trim on V1 shifts gap clip
   on A1 at the same boundary frame (existing behavior; preserved by V13).
5. **Media-boundary clamp**: trim past nested.effective_duration is
   clamped (not silently allowed); blocker keys recorded for UI.
6. **Multi-edge roll**: two edges marked `trim_type="roll"` move together
   (boundary between two clips shifts; outer clips don't move).
7. **Downstream collision retry**: shift that would overlap upstream
   triggers `retry_with_adjusted_delta`; final delta is clamped.

## Bottom line

This is a 2- to 3-session migration:

- **Session N (now done):** reading session, this walkthrough.
- **Session N+1:** migrate `command_helper.lua`. Add V13 helpers
  alongside V8 ones (don't break legacy callers yet).
- **Session N+2:** migrate `clip_mutator.lua` + write the contract test
  for BatchRippleEdit + do the surgical `batch_ripple_edit.lua`
  migration. Delete `ripple_edit.lua`. Redirect call sites.

Total est. LOC change: ~50 in batch_ripple_edit, ~150 in command_helper,
~100 in clip_mutator, ~5 deletions in call sites. Most work is reading
+ writing tests, not adding code.
