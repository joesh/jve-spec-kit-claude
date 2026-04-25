# Tasks: Timeline Placements as Nested Sequence References

**Input**: Design documents in `/Users/joe/Local/jve-spec-kit-claude/specs/013-timeline-placements-as/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/{resolver,commands,renderer}.md, quickstart.md
**Branch**: `013-timeline-placements-as`

## Conventions

- **[P]** = can run in parallel with other [P] tasks in the same phase (different files, no shared mutation).
- Every test task lists both the contract ID (CT-*) and the exact file path. Tests MUST fail before the matching implementation task runs.
- Every implementation task names the file it writes. Same file in two tasks ⇒ sequential, no [P].
- TDD gate enforced per phase: tests in phase N.a MUST be written + failing before implementation in phase N.b.
- Source tree layout per plan.md § Source Code. All paths absolute under repo root `/Users/joe/Local/jve-spec-kit-claude/`.

---

## Phase 3.1: Setup & schema (blocks everything)

### 3.1.a — Tests first

- [x] **T001 [P]** Write failing test for `sequences.kind IN ('master','nested')` CHECK constraint — attempt INSERT with `kind='timeline'`/`'compound'`/`'masterclip'`/`'multicam'`/other string; all must fail. Path: `tests/test_schema_sequences_kind_check.lua`.
- [x] **T002 [P]** Write failing test for `media_refs` table shape — INSERT a row without each NOT NULL column (`project_id`, `owner_sequence_id`, `track_id`, `media_id`, `source_in_frame`, `source_out_frame`, `timeline_start_frame`, `duration_frames`, `fps_numerator`, `fps_denominator`, `enabled`, `volume`, `playhead_frame`, `created_at`, `modified_at`); each must fail. Also test `duration_frames > 0` CHECK. Path: `tests/test_schema_media_refs.lua`.
- [x] **T003 [P]** Write failing test for `clips` column changes — assert `clip_kind`, `master_clip_id`, `media_id`, `offline` columns DO NOT exist; assert `nested_sequence_id NOT NULL`, `master_layer_track_id` (nullable, FK ON DELETE SET NULL), `fps_mismatch_policy` (nullable) DO exist. Test that INSERT without `name` fails (no default). Path: `tests/test_schema_clips_shape.lua`.
- [x] **T004 [P]** Write failing test for `media_refs_channel_state` table shape — INSERT without `enabled` or `default_gain_db` must fail (no column defaults); PK `(owner_sequence_id, channel_index)` enforced. Path: `tests/test_schema_media_refs_channel_state.lua`.
- [x] **T005 [P]** Write failing test for `clip_channel_override` table shape — INSERT without `enabled` or `gain_db` must fail; PK `(clip_id, channel_index)`; `ON DELETE CASCADE` on clip delete. Path: `tests/test_schema_clip_channel_override.lua`.
- [x] **T006 [P]** Write failing test for `projects.fps_mismatch_policy` column (NOT NULL, values in `('resample','passthrough')`). Path: `tests/test_schema_projects_fps_policy.lua`.
- [x] **T007 [P]** Write failing test for new `sequences` columns — `default_video_layer_track_id` (FK, ON DELETE SET NULL), `video_start_tc_frame`, `audio_start_tc_samples`, `fps_mismatch_policy`. Path: `tests/test_schema_sequences_new_columns.lua`.

### 3.1.b — Implementation (one file; T008 is all-or-nothing)

- [x] **T007a** Existing-test triage (rule 2.31 compliance). BEFORE T008 lands and breaks the schema out from under them, enumerate every file under `tests/` whose contents mention `clip_kind`, `master_clip_id`, `clips.media_id`, `clips.offline`, or the old `sequences.kind` string literals. For each file, classify in a committed markdown index at `specs/013-timeline-placements-as/existing-test-triage.md`:
  - **delete**: test only exercises a code path deleted by FR-018 (e.g. the old flattening Insert); delete the file.
  - **rewrite**: test exercises behavior still required under the new model but references dropped columns; rewrite the test against the new shape before T008 merges.
  - **keep**: test's expectations are orthogonal to the schema change; no action.
  Classification is reviewed by Joe before T008 lands and before any `tests/` file is modified. Rule 2.31 forbids silently rewriting expectations; explicit classification up front is the guard.
- [x] **T008** Rewrite `src/lua/schema.sql` per `specs/013-timeline-placements-as/data-model.md`:
  - Narrow `sequences.kind` CHECK to `IN ('master','nested')`.
  - Add `sequences` columns: `default_video_layer_track_id`, `video_start_tc_frame`, `audio_start_tc_samples`, `fps_mismatch_policy`.
  - Add `projects.fps_mismatch_policy TEXT NOT NULL CHECK(fps_mismatch_policy IN ('resample','passthrough'))`.
  - Create `media_refs` table + 3 indexes.
  - Narrow `clips` table — drop `clip_kind`, `media_id`, `offline`; rename `master_clip_id` → `nested_sequence_id`; add `master_layer_track_id`, `fps_mismatch_policy`; remove all column DEFAULTs on state columns; `name` NOT NULL.
  - Create `media_refs_channel_state` + `clip_channel_override` tables.
  - `clip_links` unchanged (confirm it still FK's to `clips`).
  - **Statically-verifiable INV-1 / INV-2 (rule 2.21)**: add SQLite triggers `trg_media_refs_owner_kind_insert`, `trg_media_refs_owner_kind_update`, `trg_clips_owner_kind_insert`, `trg_clips_owner_kind_update` that `RAISE(ABORT, ...)` when the joined `sequences.kind` is wrong. SQLite cannot express this as a CHECK (no subqueries), so triggers are the schema-layer path; model-layer asserts in T014/T015 are defense-in-depth.
  - Per FR-018: no migration from old schema; dropping old columns is destructive by design.
  - Run T001–T007; they must all pass.

---

## Phase 3.2: Model layer — row shapes + INV assertions

### 3.2.a — Tests first

- [x] **T009 [P]** Write failing test asserting that any `media_refs` INSERT whose `owner_sequence_id` references a `kind='nested'` sequence is refused at the model layer (INV-1). Path: `tests/test_media_ref_inv1.lua`.
- [x] **T010 [P]** Write failing test asserting that any `clips` INSERT whose `owner_sequence_id` references a `kind='master'` sequence is refused at the model layer (INV-2). Path: `tests/test_clip_inv2.lua`.
- [x] **T011 [P]** Write failing test for `would_create_cycle(owning_seq, candidate_nested_seq)` DFS (research §3) — self-reference, one-hop, two-hop, unrelated-graph. Path: `tests/test_cycle_detection.lua`.
- [x] **T012 [P]** Write failing test for INV-4 (clip window within nested seq duration). Path: `tests/test_clip_inv4_window.lua`.
- [x] **T013 [P]** Write failing test for INV-8 — `sequences.default_video_layer_track_id` must be non-NULL whenever the sequence has ≥1 video track. Creating a master with V1 then setting default to NULL must refuse. Path: `tests/test_sequence_inv8_default_layer.lua`.
- [ ] **T013a [P]** Write failing test for INV-5 — `clip_channel_override.channel_index` that points past the nested sequence's current audio channel count is rejected at resolve time with a loud assert naming the clip + channel_index (not a silent skip). Path: `tests/test_inv5_channel_index_bounds.lua`.
- [ ] **T013b [P]** Write failing test for INV-6 — deleting a master's video track with another live V track remaining: the master's `default_video_layer_track_id` repoints to a live track (or is explicitly re-set by the command) before the delete commits; deleting the last V track on a master with video clips attached refuses. Path: `tests/test_inv6_track_delete_default_repoint.lua`.
- [ ] **T013c [P]** Write failing test for INV-7 — a `clips` row has at most one row in `clip_links`; linking a clip that's already in a link group must first unlink or refuse. Path: `tests/test_inv7_link_group_single.lua`.
- [x] **T013d [P]** (+ T013b consolidated — same test) Write failing test for master-track-delete repoint-or-refuse behavior (pre-T017): given a master with V1 (default) + V2 live, deleting V1 repoints `default_video_layer_track_id` to a live V track (command chooses V2) before commit; given a master with only V1 and live clips attached, deleting V1 refuses with a clear error. Path: `tests/test_master_track_delete_default_repoint.lua`.

### 3.2.b — Implementation

- [x] **T014 [P]** Create `src/lua/models/media_ref.lua` — row create/read/update/delete; `assert_owning_is_master` (INV-1); explicit values required for `enabled`, `volume`, `playhead_frame`, `source_in_frame` (no defaults — rule 2.13). **Assert-message contract (rule 1.14)**: `assert_owning_is_master` message MUST include `media_ref.id`, `owner_sequence_id`, actual `owning_sequence.kind`, and the function name. No bare `assert(ok)`.
- [x] **T015 (partial) [P]** Narrow `src/lua/models/clip.lua` — drop `master_clip_id`/`media_id`/`clip_kind`/`offline` references; use `nested_sequence_id`; add `master_layer_track_id` getter/setter; `assert_owning_is_nested` (INV-2); `assert_window_in_nested_bounds` (INV-4). **Assert-message contract**: `assert_owning_is_nested` includes `clip.id`, `owner_sequence_id`, actual `kind`; `assert_window_in_nested_bounds` includes `clip.id`, `source_in`, `source_out`, `nested_sequence.duration`. Function names in every message.
- [x] **T016 [P]** Create `src/lua/models/cycle.lua` — `would_create_cycle(owning_seq_id, candidate_nested_seq_id)` DFS; pure; called by every command that writes a clip's `nested_sequence_id`.
- [x] **T017 (partial)** Update `src/lua/models/sequence.lua` — narrow `kind` value set to `('master','nested')`; enforce INV-8 on writes; rename/rewrite `ensure_masterclip` → `ensure_master` (kind='master' now); track-delete path on a master must set `default_video_layer_track_id` to another live video track or refuse. (Single file; not [P] with other `sequence.lua` tasks.)

---

## Phase 3.3: Resolver — single code path for preview + export

### 3.3.a — Tests first (contract tests from contracts/resolver.md)

- [x] **T018 [P]** CT-R1: master resolution (leaf) returns one `ResolvedEntry` per media_ref with correct `media_path` and provenance length 1. Path: `tests/test_resolve_master_leaf.lua`.
- [x] **T019 [P]** CT-R2: one-level nested resolution through a clip; provenance length 2; `timeline_start` translated through the clip's window. Path: `tests/test_resolve_nested_one_level.lua`.
- [x] **T020 [P]** CT-R3: three-level chain (nested → nested → master); provenance length 3. Path: `tests/test_resolve_nested_deep.lua`.
- [x] **T021 [P]** CT-R4: multicam layer override — clip's `master_layer_track_id=V2` makes the returned video entry's `media_path` come from V2's media_ref, not V1's. Path: `tests/test_resolve_layer_override.lua`.
- [x] **T022 [P]** CT-R5: audio channel disable override — `clip_channel_override(channel=2, enabled=0)` yields `enabled=false` only for channel 2. Path: `tests/test_resolve_channel_disable.lua`.
- [x] **T023 [P]** CT-R6: channel gain composition — per-clip override (-6 dB) wins over master state (-3 dB). Path: `tests/test_resolve_channel_gain.lua`.
- [x] **T024 [P]** CT-R7: cycle-asserted — direct-SQL create a cycle, call resolver, expect loud assert naming both seq ids and provenance. Path: `tests/test_resolve_cycle_assert.lua`.
- [x] **T025 [P]** CT-R8: fps-mismatch `resample` vs `passthrough` output differ per the 25/24 ratio. Path: `tests/test_resolve_fps_mismatch.lua`.
- [x] **T026 [P]** CT-R9: offline leaf yields synthetic entry with `media_path=nil`, `enabled=false`, provenance intact. Path: `tests/test_resolve_offline_leaf.lua`.
- [x] **T027 [P]** CT-R10: export parity — `export_mode=true` and `export_mode=false` produce byte-identical output for the same DB state. Path: `tests/test_resolve_export_parity.lua`.
- [x] **T028 [P]** CT-R11: deterministic ordering across repeated calls on a sequence with overlapping clips. Path: `tests/test_resolve_deterministic.lua`.
- [x] **T029 [P]** NEW (from resolver.md G-R5 fix): dangling `master_layer_track_id` — bypass FK via direct SQL to leave a live-but-dangling id, call resolver, expect loud assert with clip id + dangling track id (defense-in-depth, not a fallback). Path: `tests/test_resolve_dangling_layer_assert.lua`.
- [ ] **T029a [P]** Write failing test for INV-5 audio-channel-out-of-bounds at resolve time (paired with T013a at the resolver level). Path: `tests/test_resolve_channel_index_oob_assert.lua`.
- [x] **T029b [P]** Write failing test for the thin-wrapper retrofit (pre-T031): `get_video_in_range` and `get_audio_in_range` return the SAME flat-entry shape the current TMB consumer expects, filtered by `media_kind`. Drives TMB compatibility without forking the resolver. Path: `tests/test_resolve_wrapper_shape.lua`.

### 3.3.b — Implementation

- [x] **T030** Implement `Sequence:resolve_in_range(seq_id, start_frame, end_frame, context)` in `src/lua/models/sequence.lua` per `contracts/resolver.md`. **Rule 2.5/2.6: `resolve_in_range` is the orchestrator; each responsibility lives in a named helper ≤ 30 lines.** Required decomposition:
  - `resolve_master_leaf(seq_id, range, context)` — iterate `media_refs`, clip to range, emit leaf entries with `media_id → media.file_path`, apply `media_refs_channel_state`.
  - `resolve_nested_clips(seq_id, range, context)` — iterate overlapping `clips`, recurse per clip.
  - `apply_layer_selector(clip, nested_tracks)` — pure: filter the nested sequence's V tracks to the clip's `master_layer_track_id` or the nested sequence's `default_video_layer_track_id`; audio unfiltered.
  - `apply_channel_overrides(clip, audio_entries)` — pure: join with `clip_channel_override`; on absent row, inherit; on override row, apply `enabled`/`gain_db`.
  - `compose_gain(factors)` — pure multiply over a collected list of factors (clip, inherited, leaf). **Do not accumulate a running product across recursion levels** (MEMORY rule "never accumulate derived values"); collect factors through `provenance`, multiply once at emission. Drift-free.
  - `translate_window(clip, inner_entries)` — pure: shift `timeline_start` by `(clip.timeline_start - clip.source_in)` (G-R7).
  - `build_provenance(outer_chain, leaf_id)` — pure list-append.
  - `assert_no_cycle(context, seq_id)` — G-R2 `recursing_into` guard, loud-assert with chain.
  - `assert_layer_ref_valid(clip)` — G-R5 loud-assert if `master_layer_track_id` points at a dead track (no fallback — rule 2.13).
  - `emit_offline_entry(chain)` — synthetic `ResolvedEntry` with `media_path=nil`, `enabled=false`, provenance intact.
  - `resolve_fps_policy(clip, context)` — returns `'resample'` or `'passthrough'` per clip → sequence → project chain (G-R4).
  - The orchestrator function reads as a high-level algorithm (rule 2.5): guard → dispatch on `kind` → iterate → recurse → apply overrides in declared order → translate → compose.
  - Runs T018–T029; all pass.
- [x] **T031** Thin-wrapper retrofit (landed 2f85c769): update `src/lua/models/sequence.lua`'s existing `get_video_in_range` and `get_audio_in_range` to invoke `resolve_in_range` and filter the returned entries by `media_kind`. Before starting: grep for `get_video_in_range` / `get_audio_in_range` call sites, enumerate the exact columns/fields each caller reads from the returned entries in a committed sibling artifact `specs/013-timeline-placements-as/wrapper-shape-audit.md`, and verify each column survives the wrapper unchanged. No coalescing or renaming; wrapper preserves the existing entry shape column-for-column. (Same file as T030 — sequential.) Preceded by T029b failing test.

---

## Phase 3.4: Rewired editing commands

Every rewired command's behavior is covered by an existing test suite plus a new contract test per `contracts/commands.md`. Tests first, then implementation. All commands include `sequence_id` in args per rule 2.29; commands that write a clip's `nested_sequence_id` run `would_create_cycle` before write (INV-3); all commands emit `sequence_content_changed(sequence_id)`.

### 3.4.a — Tests first

- [x] **T032 [P]** CT-C1 Insert: dropping a master with V and stereo audio creates exactly 2 `clips` rows (V + A), both with correct `nested_sequence_id`, NULL `master_layer_track_id`, non-NULL `fps_mismatch_policy`, joined by one `clip_links.link_group_id`. **Parametrized over both policies**: 25fps master on 24fps timeline gives `duration_frames=96` under `resample` and `duration_frames=100` under `passthrough`; `source_out_frame=100` in both. Also covers the Insert optional-arg path (explicit policy overrides the inherited default). Path: `tests/test_insert_creates_linked_clips.lua`.
- [x] **T033 [P]** CT-C2 Overwrite: overlapping clip trimmed, new clip occupies [start, start + duration_under_policy). Parametrized over both policies. Path: `tests/test_overwrite_trims_overlap.lua`.
- [x] **T034 [P]** CT-C3 Trim (head): `source_in` and `timeline_start` update by the trim amount in the nested sequence's timebase. Path: `tests/test_013_trim_head_tail.lua` (covers TrimHead + TrimTail in one file — paired contracts).
- [x] **T035 [P]** CT-C4/C5/C6 Slip/Slide/Roll — one test per command; all arithmetic in nested-sequence timebase; out-of-bounds loud-fail. Path: `tests/test_slip_slide_roll.lua`.
- [x] **T036 [P]** CT-C7 Split preserves overrides on both halves. Path: `tests/test_split_preserves_overrides.lua`.
- [x] **T036a [P]** CT-C7b Blade (razor-at-playhead across linked tracks) — Blade at playhead on armed tracks splits every linked clip at the playhead, preserving the link group on each resulting half-pair (distinct from a single-clip Split). If commands.md treats Blade as a synonym for Split, this test documents that — one failing test forces the distinction decision. Path: `tests/test_blade_across_linked_tracks.lua`.
- [x] **T037 [P]** CT-C8 Duplicate copies `master_layer_track_id`, `fps_mismatch_policy`, and all `clip_channel_override` rows. Path: `tests/test_duplicate_copies_overrides.lua`.
- [x] **T038 [P]** Ripple-delete preserves link group (Acceptance Scenario 8 / FR-003). Path: `tests/test_ripple_delete_link_group.lua`.
- [x] **T039 [P]** Cycle refusal on Insert: attempt to nest a sequence inside itself (direct + transitive) must refuse with a user-visible error; no DB mutation. Path: `tests/test_insert_cycle_refuse.lua`.
- [x] **T039a [P]** `sequence_content_changed` signal contract — subscribe a spy, drive one representative from each command class (Insert, Overwrite, Trim, Duplicate, SetClipLayer, ToggleClipChannel, SetMasterDefaultLayer, SetMasterChannelState, SetSequenceStartTC, Nest, Unnest, GrowMasterMedium), assert the signal fires with the correct `sequence_id` for each. Without this, silent omission of the signal in any command would go undetected. Path: `tests/test_signal_sequence_content_changed.lua`.

### 3.4.b — Implementation

- [x] **T040 [P]** Rewrite `src/lua/core/commands/insert.lua` — no flattening; insert 1 or 2 `clips` rows with `nested_sequence_id` = the master; cycle check; link-group creation; ripple on target tracks.
- [x] **T041 [P]** Rewrite `src/lua/core/commands/overwrite.lua` — same shape as Insert, overlap removed/trimmed.
- [x] **T042 [P]** Rewrite `src/lua/core/commands/add_clips_to_sequence.lua` — emit clip rows referencing sequences only; no `media_id`/`clip_kind` references.
- [x] **T043 [P]** Rewrite `src/lua/core/commands/trim_head.lua` and `trim_tail.lua` — units are nested sequence's timebase. (Two files, still [P] with each other.)
- [x] **T044 [P]** Rewrite `src/lua/core/commands/slip.lua`, `slide.lua`, `roll.lua`. (Three files, [P].)
- [x] **T045 [P]** Rewrite `src/lua/core/commands/split_clip.lua` — single-clip Split; override copy to both halves; new link_group for each half. Precondition: T036 passes.
- [x] **T045a [P]** Rewrite `src/lua/core/commands/blade.lua` — razor-at-playhead across armed tracks; preserves link group integrity per T036a. If implementation finds Blade and Split share enough code to refactor into a `split_at(clip_ids_by_track, frame)` helper, do it; but each command's contract is distinct and both contracts must pass.
- [ ] **T046 [P]** Rewrite the ripple + extend + delete command set. For each file listed below: remove any read/write of `clip.media_id` / `clip.clip_kind` / `clip.master_clip_id` / `clip.offline`; replace with `clip.nested_sequence_id` + resolver-driven lookups where a preview of post-mutation state is needed. No silent schema migration inside the command; if a query previously projected `media_id`, project `nested_sequence_id` explicitly and follow the chain through the model layer (no inline SQL JOINs to `media_refs` — let `media_ref.lua` / `sequence.lua` own the chain walk). Exact files (enumerate so [P] parallelism is verifiable):
  - `src/lua/core/commands/extend_edit.lua`
  - `src/lua/core/commands/ripple_insert.lua`
  - `src/lua/core/commands/ripple_overwrite.lua`
  - `src/lua/core/commands/ripple_delete.lua`
  - `src/lua/core/commands/ripple_trim.lua`
  - `src/lua/core/commands/delete_clip.lua`
  - `src/lua/core/commands/delete_range.lua`
  (Verify these exact filenames against `ls src/lua/core/commands/` before starting; any file not present is dropped from this task and flagged for follow-up.)
- [x] **T047 [P]** Rewrite `src/lua/core/commands/duplicate.lua` — copy overrides + `clip_channel_override` rows.

---

## Phase 3.5: New override commands

### 3.5.a — Tests first

- [ ] **T048 [P]** CT-C9 SetClipLayer — NULL ↔ V2; undo restores prior. Args must include `sequence_id` (rule 2.29 regression). Path: `tests/test_set_clip_layer.lua`.
- [ ] **T049 [P]** CT-C10 ToggleClipChannel — first toggle inserts override row with materialized inherited gain; second toggle flips `enabled`; undo deletes the row. Path: `tests/test_toggle_clip_channel.lua`.
- [ ] **T050 [P]** CT-C11 SetClipChannelGain — insert/update; undo restores row-absence if didn't exist. Path: `tests/test_set_clip_channel_gain.lua`.
- [ ] **T051 [P]** CT-C12 ClearClipOverride — channel variant deletes row; layer variant NULLs `master_layer_track_id`; playback reflects inherited state. Path: `tests/test_clear_clip_override.lua`.
- [ ] **T052 [P]** FR-020 coverage: five rapid channel toggles produce five undo steps (no coalescing), each with descriptive label. Path: `tests/test_override_undo_granularity.lua`.
- [ ] **T052a [P]** Insert/Overwrite atomic-undo (multi-row commands): a single undo of Insert reverses all rows the command wrote (V clip + A clip + link_group). A single undo of Overwrite restores trimmed/removed clips and removes the new clip. Distinct from T052 (per-override granularity); this one asserts multi-row structural commands stay atomic. Path: `tests/test_insert_overwrite_atomic_undo.lua`.

### 3.5.b — Implementation

- [ ] **T053 [P]** Create `src/lua/core/commands/set_clip_layer.lua`.
- [ ] **T054 [P]** Create `src/lua/core/commands/toggle_clip_channel.lua` — materializes inherited gain on first toggle (rule 2.13 — no DEFAULT-0 sneak-through).
- [ ] **T055 [P]** Create `src/lua/core/commands/set_clip_channel_gain.lua`.
- [ ] **T056 [P]** Create `src/lua/core/commands/clear_clip_override.lua` — accepts `kind='channel'` or `kind='layer'`.

---

## Phase 3.6: Master-level + sequence-level commands

### 3.6.a — Tests first

- [ ] **T057 [P]** CT-C13 SetMasterDefaultLayer — V1 → V2 changes all tracking clips' exposed layer; clips with their own override unaffected. Path: `tests/test_set_master_default_layer.lua`.
- [ ] **T058 [P]** CT-C14 SetMasterChannelState — upsert propagates to tracking clips; overridden clips untouched. Path: `tests/test_set_master_channel_state.lua`.
- [ ] **T059 [P]** CT-C15 SetSequenceStartTC — propagates to timeline-position translation for all referencing clips. Path: `tests/test_set_sequence_start_tc.lua`.
- [ ] **T059a [P]** FR-017 default-derivation coverage: a freshly-imported master's `video_start_tc_frame` is derived from its first video media_ref's native TC; `audio_start_tc_samples` from its first audio media_ref. A freshly-imported non-master's defaults derive from its first video clip / first audio clip. Independent of SetSequenceStartTC (which tests the edit path); this tests the derive-at-creation path. Path: `tests/test_sequence_start_tc_defaults.lua`.
- [ ] **T060 [P]** CT-C16 SetFpsMismatchPolicy — project scope writes `projects.fps_mismatch_policy` (no effect on existing clips); sequence scope writes `sequences.fps_mismatch_policy` (no effect on existing clips); **clip scope is structural**: re-computes `clips.duration_frames` under the new policy, ripples downstream on the track, and flips linked V+A pair together as a unit. Parametrized 25fps master on 24fps timeline: flipping from `passthrough` (100 frames) to `resample` (96 frames) shortens the clip and pulls downstream clips back by 4. Path: `tests/test_set_fps_mismatch_policy.lua`.
- [ ] **T060a [P]** Scenario-7 owning command coverage (FR-007): when a master's shape changes (gain an audio track in a video-only master, or gain a video track in an audio-only master), every existing clip that references that master gains a linked companion clip on the new medium, sharing the clip's `link_group_id`. Test drives a `GrowMasterMedium` (or equivalent — see T064a) command and asserts the effects on all five of the Scenario-7 clips; verifies prior clips' other overrides persist untouched. Path: `tests/test_grow_master_medium_propagates.lua`.

### 3.6.b — Implementation

- [ ] **T061 [P]** Create `src/lua/core/commands/set_master_default_layer.lua` — refuses if `track_id` doesn't belong to the master's V tracks; INV-8 check.
- [ ] **T062 [P]** Create `src/lua/core/commands/set_master_channel_state.lua` — UPSERT `media_refs_channel_state`; explicit `enabled`+`gain_db` required.
- [ ] **T063 [P]** Create `src/lua/core/commands/set_sequence_start_tc.lua` — Args `{ sequence_id, medium ∈ {'video','audio'}, tc_value }` (rule 2.29 — `sequence_id` required).
- [ ] **T064 [P]** Create `src/lua/core/commands/set_fps_mismatch_policy.lua` — dispatch on `scope`:
  - `scope='project'` Args: `{ project_id, policy ∈ {'resample','passthrough'} }` (non-NULL). UPDATE only; no effect on existing clips.
  - `scope='sequence'` Args: `{ sequence_id, policy ∈ {'resample','passthrough',NULL} }` (rule 2.29). NULL = inherit project. UPDATE only; no effect on existing clips.
  - `scope='clip'` Args: `{ sequence_id, clip_id, policy ∈ {'resample','passthrough'} }` where `sequence_id = clip.owner_sequence_id` (rule 2.29). **Structural mutation**: loads the clip's nested_sequence + owner sequence, re-computes `duration_frames` (`resample`: `round(nested.duration × owner.fps / nested.fps)`; `passthrough`: `nested.duration`), UPDATEs the clip, ripples downstream clips on the track by `(new_duration - old_duration)`, and processes linked clips in the same `link_group_id` as a unit.
- [ ] **T064a [P]** Create `src/lua/core/commands/grow_master_medium.lua` (owning command for FR-007 / Scenario 7). Args: `{ sequence_id, medium ∈ {'video','audio'}, track_spec }` where `sequence_id.kind='master'`. Mutations:
  1. INSERT a new track on the master + its associated media_refs per `track_spec`.
  2. For every `clips` row with `nested_sequence_id = sequence_id` that lacks a companion on the new medium, INSERT a new clips row mirroring position/duration with `master_layer_track_id=NULL`, and INSERT a `clip_links` row attaching it to the original clip's `link_group_id` (creating a link group if none existed).
  3. Emit `sequence_content_changed(sequence_id)` plus `sequence_content_changed(clip.owner_sequence_id)` for every parent sequence touched.
  Undo capture: full before-state. Rule 2.29: `sequence_id` in args.

---

## Phase 3.7: Nest / Unnest

### 3.7.a — Tests first

- [ ] **T065 [P]** CT-C17 Nest — 3 selected clips in a non-master sequence become 3 clips inside a new `kind='nested'` sequence; parent has one new clip replacing them. Path: `tests/test_nest.lua`.
- [ ] **T066 [P]** CT-C18 Unnest — clip whose `nested_sequence_id.kind='nested'` expands back into parent; nested sequence orphan-deleted if no other references. Path: `tests/test_unnest.lua`.
- [ ] **T067 [P]** CT-C19 Unnest refusal — attempting Unnest on a clip whose `nested_sequence_id.kind='master'` refuses with clear error; no mutation. Path: `tests/test_unnest_refuse_master.lua`.
- [ ] **T067a [P]** Unnest orphan-delete observability — when Unnest's orphan-cleanup deletes the nested sequence, the command emits a `sequence_deleted(sequence_id)` signal and records the deletion in its undo-capture so that undo resurrects the sequence with its contents. Silent DB deletion is forbidden (MEMORY: "no silent DB record creation"). Path: `tests/test_unnest_orphan_delete_observable.lua`.
- [ ] **T067b [P]** Nest-and-Unnest undo atomicity — a single undo of `Nest` reverses the entire mutation set (new sequence + all moved clips + new parent clip + link_group); a single undo of `Unnest` restores the deleted clip + all moved clips + the orphan-deleted sequence (if any). Asserts command_manager group semantics (FR-020 is per-override only — multi-row structural commands are atomic). Path: `tests/test_nest_unnest_undo_atomicity.lua`.

### 3.7.b — Implementation

- [ ] **T068 [P]** Create `src/lua/core/commands/nest.lua`.
- [ ] **T069 [P]** Create `src/lua/core/commands/unnest.lua` — refuses on masters; performs orphan cleanup.

---

## Phase 3.8: Importers (emit new shape)

### 3.8.a — Tests first

- [ ] **T070 [P]** DRP importer integration test: every synced clip produces one `kind='master'` sequence with V1 media_ref → .mov + N audio media_refs → external WAV channels; edit timelines contain clips with non-NULL `nested_sequence_id`. Path: `tests/integration/test_drp_emits_new_shape.lua`.
- [ ] **T071 [P]** FCP7 XMEML importer integration test: same shape assertions. Path: `tests/integration/test_fcp7_emits_new_shape.lua`.
- [ ] **T072 [P]** Premiere .prproj importer integration test: same. Path: `tests/integration/test_prproj_emits_new_shape.lua`.
- [ ] **T073 [P]** Drag-drop / `media_reader` integration test: dropping a loose file creates a `kind='master'` sequence with media_refs + a clip on the current edit sequence. Path: `tests/integration/test_drag_drop_emits_new_shape.lua`.
- [ ] **T073a [P]** Importer error-path tests (rule 2.32): malformed DRP (truncated FieldsBlob), FCP7 XMEML with missing media refs, .prproj referencing a file not on disk, drag-drop of a non-media file. Each must fail loudly with a user-visible error and leave no partial rows behind. Path: `tests/integration/test_importer_error_paths.lua`.
- [ ] **T073b [P]** Importer cycle-refusal test: a source project that (when translated) would produce a cycle must be refused at import time with a clear error; no partial sequences left. Path: `tests/integration/test_importer_cycle_refusal.lua`.

### 3.8.b — Implementation

- [ ] **T074 [P]** Update `src/lua/importers/drp_importer.lua` — build masters with media_refs (not flattened timeline clips); `ensure_master` wiring.
- [ ] **T075 [P]** Update `src/lua/importers/fcp7_xml_importer.lua` — same.
- [ ] **T076 [P]** Update `src/lua/importers/prproj_importer.lua` — same.
- [ ] **T077 [P]** Update `src/lua/media/media_reader.lua` — drag-drop flow creates master + media_refs + clip on current edit sequence.

---

## Phase 3.9: Renderer + Inspector (pull surfaces)

### 3.9.a — Tests first

- [ ] **T078 [P]** CT-RN1 waveform path through a clip resolves via `nested_sequence_id` → master's audio media_refs → `media.peak_file`. Path: `tests/test_renderer_waveform_chain.lua`.
- [ ] **T079 [P]** CT-RN2 layer selection affects color. Path: `tests/test_renderer_layer_color.lua`.
- [ ] **T080 [P]** CT-RN3 offline propagates through chain. Path: `tests/test_renderer_offline_chain.lua`.
- [ ] **T081 [P]** CT-RN4 override edit triggers one-frame re-resolve. Path: `tests/test_renderer_override_redraw.lua`.
- [ ] **T082 [P]** CT-RN5 broken chain loud-fail overlay. Path: `tests/test_renderer_broken_chain_loud.lua`.
- [ ] **T083 [P]** CT-RN6 master-interior view shows media_refs, not clips. Path: `tests/test_renderer_master_interior.lua`.
- [ ] **T084 [P]** CT-IN1 inspector dispatches commands (not direct DB writes). Path: `tests/test_inspector_dispatches_commands.lua`.
- [ ] **T085 [P]** CT-IN2 master-level edit propagates to tracking clips. Path: `tests/test_inspector_master_propagation.lua`.
- [ ] **T086 [P]** CT-IN3 revert-to-default button deletes override row. Path: `tests/test_inspector_revert_override.lua`.
- [ ] **T087 [P]** CT-IN4 identical inspector shape for `default_video_layer_track_id` + start-TCs regardless of `kind`. Path: `tests/test_inspector_shared_sequence_fields.lua`.
- [ ] **T088 [P]** CT-PREF1 loud-fail indicator preference toggle. Path: `tests/test_renderer_loud_fail_pref.lua`.

### 3.9.b — Implementation

- [ ] **T089 [P]** Update `src/lua/ui/timeline/view/timeline_view_renderer.lua` — branch on focused sequence's `kind`: query `media_refs` for masters, `clips` for non-masters. Waveform/offline walks the chain `clips.nested_sequence_id → media_refs → media`. MUST NOT read `clips.media_id` (column is gone). MUST NOT cache across `mutation_generation` bumps on any sequence in the chain. **Rule 2.13 / rule 1.14**: a broken chain link (missing nested sequence, deleted track with no FK fallback, missing media_ref on the selected layer) is surfaced via the FR-022 loud-fail overlay AND via assert (message names the clip_id, nested_sequence_id, and the first dead link in the chain); no silent empty-render fallback. **Rule 2.5**: extract chain-walking into a named helper (`resolve_clip_display_leaf(clip)`) rather than inlining into the draw loop. **MVC pull semantics**: renderer pulls from model on every paint during park mode; push-path stays for the 60Hz playback hot path only.
- [ ] **T090 [P]** Update `src/lua/ui/inspector/schema.lua` — add clip inspector (layer override, per-channel overrides, fps policy), master inspector (default layer, start TCs, channel state), media_ref inspector (file + window). Independent of T089 (different file, no shared module).

---

## Phase 3.10: Playback + export wiring

### 3.10.a — Tests first

- [ ] **T091 [P]** FR-012 playback through a clip decodes correct video and audio for single-file + synced + multicam + nested-nested-master chain. Path: `tests/integration/test_playback_recursion.lua`.
- [ ] **T091a [P]** Pre-T093 unit test: `playback_engine` reads via `resolve_in_range` (or the wrappers); no remaining `clip.media_id` reads (static grep-assertion inside the test, failing if the identifier reappears in `src/lua/core/playback/`). Path: `tests/test_playback_engine_no_legacy_reads.lua`.
- [ ] **T092 [P]** FR-019 export parity — preview a range, export the range, both outputs identical (same files, windows, channel states) within codec tolerance. Path: `tests/integration/test_export_parity.lua`.
- [ ] **T092a [P]** Pre-T094 unit test: export-only policies (codec, bit depth, colorspace, proxy-vs-source, resample filter quality) are applied in the export pipeline ABOVE `resolve_in_range`, never inside the resolver. Test: call `resolve_in_range` with `export_mode=true` AND with a probe `context` whose extra fields would be illegal inside the resolver — verify output doesn't vary. Path: `tests/test_export_policy_above_resolver.lua`.
- [ ] **T092b [P]** C++ TMB shape-preservation check. Plan.md asserts "no C++ changes required" for this feature; this task verifies that claim holds. Enumerate every C++ site that reads fields off a clip/media entry passed from Lua (grep `src/**/*.cpp` and `src/**/*.h` for `"media_id"`, `"source_in"`, `"source_out"`, `"clip_kind"`, `"timeline_start"`, etc. as string keys in `lua_getfield`/`sol::`/equivalent lookups). For each C++ read, verify the corresponding Lua entry emitted by T031's wrappers still carries the same key with the same type. If any key is renamed or removed, either update T031 to preserve the key in the wrapper (preferred — rule 2.18 FFI stability) or add a C++ edit task + test. Output: a markdown checklist committed at `specs/013-timeline-placements-as/cxx-shape-audit.md`. Path for the automated guard: `tests/test_cxx_shape_audit.lua` (greps the C++ keys and the Lua emission to confirm parity).

### 3.10.b — Implementation

- [ ] **T093** Update `src/lua/core/playback/playback_engine.lua` — replace every `clip.media_id` / `clip.clip_kind` / `clip.master_clip_id` / `clip.offline` read with the resolver-driven chain (via `get_video_in_range`/`get_audio_in_range` wrappers from T031, or `resolve_in_range` directly if the caller wants unfiltered entries). No shim to preserve old calling patterns; rewrite the consumer to the new entry shape. T091a grep-assertion gates the file.
- [ ] **T094** Create `src/lua/core/export/export_engine.lua` — shares `resolve_in_range` with playback (FR-019); export-only policies (codec, bit-depth, colorspace, proxy-vs-source, resample filter) applied in the pipeline ABOVE the resolver, never inside it.

---

## Phase 3.11: End-to-end acceptance validation (maps to quickstart.md)

One integration test per spec Acceptance Scenario + the extra quickstart items.

- [ ] **T095 [P]** Scenario 1 — Single-file A/V drop creates V+A linked clips; playback decodes both. Path: `tests/integration/test_scenario1_single_file_av.lua`.
- [ ] **T096 [P]** Scenario 2 — DRP synced clip: V from .mov, A from WAV; per-channel disable silences that channel only. Path: `tests/integration/test_scenario2_synced_av.lua`.
- [ ] **T097 [P]** Scenario 3 — Multicam layer change on one clip leaves other clips unaffected. Path: `tests/integration/test_scenario3_multicam_layer.lua`.
- [ ] **T098 [P]** Scenario 4 — Disable audio channel on a clip; other clips of same master unaffected. Path: `tests/integration/test_scenario4_channel_disable.lua`.
- [ ] **T099 [P]** Scenario 5 — Trim a clip; master unchanged; no other clip affected. Path: `tests/integration/test_scenario5_trim_clip.lua`.
- [ ] **T100 [P]** Scenario 6 — Master content change propagates to all clips. Path: `tests/integration/test_scenario6_master_content_propagation.lua`.
- [ ] **T101 [P]** Scenario 7 — Video-only master gains audio track; existing clips gain linked A clip (track-the-master default). Path: `tests/integration/test_scenario7_master_gains_audio.lua`.
- [ ] **T102 [P]** Scenario 8 — Ripple-delete preserves link group + downstream shift. Path: `tests/integration/test_scenario8_ripple_delete_link.lua`.
- [ ] **T103 [P]** Scenario 9 — All importers emit non-NULL `nested_sequence_id` on every edit-timeline clip; no `media_id` directly on clips. Path: `tests/integration/test_scenario9_importers_emit_refs.lua`.
- [ ] **T104 [P]** Scenario 10 — Master default layer change propagates to tracking clips. Path: `tests/integration/test_scenario10_master_default_layer.lua`.
- [ ] **T105 [P]** Scenario 11 — Master-level channel state propagates to tracking clips. Path: `tests/integration/test_scenario11_master_channel_state.lua`.
- [ ] **T106 [P]** Nest/Unnest round-trip preserves positions; unnest refuses on masters. Path: `tests/integration/test_nest_unnest_roundtrip.lua`.
- [ ] **T107 [P]** Cycle refusal — integration coverage distinct from T039 (which tests Insert-path only). T107 drives cycle attempts through **every command path** that can create a clip's `nested_sequence_id`: Insert, Overwrite, Duplicate, Nest, and direct-SQL cycle (resolver defense-in-depth assert from T024). Each path surfaces a user-visible error with no partial DB state. Path: `tests/integration/test_cycle_refusal.lua`.
- [ ] **T108 [P]** Offline loud-fail overlay visible by default; suppressed by preference; log entries persist regardless (FR-022). Path: `tests/integration/test_offline_loud_fail.lua`.

---

## Phase 3.12: Legacy cleanup (FR-018)

- [x] **T108a** Add a standing **banned-identifier regression test** (landed a9f8557b; 376 hits current, red until T109) that `grep -R`'s the source tree for legacy identifiers and fails if any reappear: `clip_kind`, `master_clip_id`, `\.media_id` on `clips\.` references, `\.offline` on `clips\.`, and the old `sequences.kind` string literals (`'timeline'`, `'masterclip'`, `'compound'`, `'multicam'`). Enforces FR-018 going forward (rule 2.15). Path: `tests/test_no_legacy_identifiers.lua`.
- [ ] **T109** Scoped legacy purge — impl tasks T042/T046/T089 already removed the identifiers from `src/lua/core/commands/` and `src/lua/ui/timeline/view/` by rewriting those files. T109 handles the remainder:
  - Enumerate `tests/fixtures/**/*.jvp` files whose schema predates T008. For each: regenerate via the updated importer under the new shape, OR present the unreferenced-by-current-tests list to Joe and delete only on approval (unreferenced today ≠ safe — may be a planned-use asset).
  - Grep `src/**/*.cpp` and `src/**/*.h` for any C++ reference to the dropped columns; remove.
  - Grep `docs/**`, `specs/**` for stale references to `clip_kind`, `master_clip_id`, `clips.media_id`; update prose to match current model.
  - Run T108a; it must pass.
- [ ] **T110** Run `make -j4` from repo root; zero luacheck warnings, zero compile warnings, all tests green. Run `tests/run_integration_tests.sh`; all integration tests green.
- [ ] **T111** Execute `specs/013-timeline-placements-as/quickstart.md` manually end-to-end with `./build/bin/JVEEditor`. Each of the 11 scenarios + Nest/Unnest + export parity + cycle refusal + offline loud-fail produces the expected observable result.

---

## Dependencies

```
T001–T007 (schema tests)              ──▶ T008 (schema write)       ──▶ everything else
T009–T013d (model-INV tests incl. 5/6/7/track-delete)
                                      ──▶ T014–T017 (model impl)
T018–T029b (resolver + wrapper tests) ──▶ T030–T031 (resolver + wrapper impl)
T032–T039a (rewired-cmd tests)        ──▶ T040–T047 (rewired-cmd impl)   [needs models T014–T017 only; resolver is NOT a prereq — commands mutate rows, they don't resolve]
T048–T052a (override-cmd tests)       ──▶ T053–T056 (override-cmd impl)  [needs models]
T057–T060a (master-cmd tests)         ──▶ T061–T064a (master-cmd impl)   [needs models]
T065–T067b (nest tests)               ──▶ T068–T069 (nest impl)          [needs INV-2]
T070–T073b (importer + error tests)   ──▶ T074–T077 (importer impl)      [needs models+cmds]
T078–T088 (render/inspector tests)    ──▶ T089–T090 (render/inspector impl)   [T089 needs T030 resolver]
T091–T092b (playback+export tests)    ──▶ T093–T094 (playback/export impl)   [needs T030/T031]
T095–T108 (scenario integrations)     ──▶ block on all impl phases complete
T108a (banned-identifier regression)  ──▶ T109 (scoped cleanup)
T109–T111 (cleanup + validation)      ──▶ last
```

Cross-phase dependencies:
- T008 (schema) blocks everything.
- T014–T017 (models + INVs + cycle) blocks all command phases (commands mutate rows via the model layer and must respect INV-1..INV-8).
- T030 (resolver) blocks T089 (renderer chain walk) and T093/T094 (playback/export consume it). Commands T040–T069 do NOT depend on the resolver — they mutate rows only.
- T007a (existing-test triage) blocks T008 (rule 2.31 — must classify before schema shift breaks them).
- T108a (banned-identifier regression test) is standing; it watches forever once added, and gates T109.

## Parallel execution examples

### Phase 3.1.a — all schema tests at once
```
Task: "Write failing test for sequences.kind CHECK in tests/test_schema_sequences_kind_check.lua"
Task: "Write failing test for media_refs shape in tests/test_schema_media_refs.lua"
Task: "Write failing test for clips column changes in tests/test_schema_clips_shape.lua"
Task: "Write failing test for media_refs_channel_state in tests/test_schema_media_refs_channel_state.lua"
Task: "Write failing test for clip_channel_override in tests/test_schema_clip_channel_override.lua"
Task: "Write failing test for projects.fps_mismatch_policy in tests/test_schema_projects_fps_policy.lua"
Task: "Write failing test for new sequences columns in tests/test_schema_sequences_new_columns.lua"
```

### Phase 3.3.a — all 12 resolver contract tests at once (T018–T029)
```
Task: "CT-R1 master leaf resolution in tests/test_resolve_master_leaf.lua"
Task: "CT-R2 one-level nested resolution in tests/test_resolve_nested_one_level.lua"
...
Task: "Dangling layer id asserts in tests/test_resolve_dangling_layer_assert.lua"
```

### Phase 3.4.b — all rewired command implementations (T040–T047)
Different files; all [P] safe except T043 which touches two related files (trim_head, trim_tail).

### Phase 3.11 — all 14 end-to-end scenarios (T095–T108)
All independent integration test files, fully parallel.

## Validation gates (template compliance)

- [x] Every contract file (`resolver.md`, `commands.md`, `renderer.md`) has contract-test tasks.
- [x] Every entity/table in `data-model.md` (`sequences` deltas, `media_refs`, `clips` deltas, `media_refs_channel_state`, `clip_channel_override`, `projects` delta) has a schema-test + model task.
- [x] Every invariant (INV-1..INV-8) is covered by a failing test before its enforcement lands (INV-1 T009, INV-2 T010, INV-3 T011/T039/T107, INV-4 T012, INV-5 T013a/T029a, INV-6 T013b/T013d, INV-7 T013c, INV-8 T013).
- [x] Every command in `commands.md` has a contract-test + implementation task.
- [x] Every CT-R*, CT-C*, CT-RN*, CT-IN*, CT-PREF* maps to exactly one task (T018–T029, T032–T039, T048–T067, T078–T088).
- [x] Every quickstart scenario maps to one integration test (T095–T108).
- [x] Tests precede implementation in every phase (TDD gate).
- [x] Every [P] task writes to a distinct file.
- [x] Every task names its exact file path.
- [x] No task modifies the same file as another [P] task in the same phase.
- [x] Rule 2.29 (`sequence_id` on timeline commands) covered by test T048 as a regression gate.
- [x] FR-018 (no back-compat) enforced by T109.
- [x] FR-019 (export parity) enforced by T092 + T027 (CT-R10).
- [x] FR-020 (one-undo-per-override) enforced by T052.
- [x] FR-021 (vocabulary) — docs-only; verified by spec/quickstart review, not a runtime task.
- [x] FR-022 (loud-fail) enforced by T082 + T088 + T108.
- [x] FR-007 retroactive A-clip on master shape-change: owning command T064a; test T060a; integration T101.
- [x] FR-017 default-derivation path tested by T059a (edit path by T059/T063).
- [x] Split vs Blade distinct contracts: T036 + T036a tests, T045 + T045a impls.
- [x] Nest/Unnest observability: T067a signal + T067b undo atomicity.
- [x] Multi-row command undo atomicity: T052a (Insert/Overwrite), T067b (Nest/Unnest) — distinct from FR-020 per-override granularity.
- [x] `sequence_content_changed` signal contract: T039a spy test.
- [x] Rule 2.31 compliance: T007a existing-test triage gates T008.
- [x] Rule 1.14 assert-message contracts: T014/T015 name required id fields; T013a/T013b/T029/T029a inherit the same discipline.
- [x] MVC park-mode pull semantics called out in T089.
- [x] Rule 2.18 FFI stability: T092b C++ shape audit verifies `no C++ changes required`.
- [x] Gain composition: T030 `compose_gain` explicitly forbids accumulate-across-recursion.

## Notes

- Estimated total: **~140 tasks** (T001–T111 plus two audit passes of lettered insertions: T007a, T013a–d, T029a/b, T036a, T039a, T045a, T052a, T059a, T060a, T064a, T067a/b, T073a/b, T091a, T092a/b, T108a). Heavier than the template's 40–55 guide because this refactor touches 12+ editing commands, 4 importers, 3 contract surfaces, and 14 acceptance scenarios — all identified up front to avoid mid-implementation drift.
- Keep commits small per task; the branch is long-lived and may need bisection.
- When a task writes Lua, always run `make -j4` locally before claiming the task done (rule 2.4). For Lua-only changes use `make JVEEditor -j4` if iterating UI, full `make -j4` before commit.
- Every failing-test task must be demonstrably failing (run it, capture the failure) BEFORE its matching implementation task begins (rule 2.20).
- **Rule 2.8 commit attribution**: every commit's trailer includes `Authored-By: Joe Shapiro <joe@shapiro.net>` and `With-Help-From: Claude`. No exceptions.
- **Joe-review gates** (tasks that produce artifacts requiring Joe's scope decision before the next task runs):
  - T007a (`existing-test-triage.md`) reviewed by Joe before T008 merges.
  - T092b (`cxx-shape-audit.md`) reviewed by Joe; its finding may invalidate plan.md's "no C++ changes" claim, which changes scope.
  - T109 fixture cleanup: enumerate unreferenced `tests/fixtures/**/*.jvp` files and present to Joe; delete only on approval. Unreferenced-today ≠ safe-to-delete — a fixture may be a planned-use asset.
