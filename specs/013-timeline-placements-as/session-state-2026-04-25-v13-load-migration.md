# 013 session state — 2026-04-25 — V13 load_clips/Clip.load + bulk fixture migration

## TL;DR

Migrated the load-side of the V13 schema (SELECT path) and bulk-migrated test
fixtures across the suite. Tests went **332 → 466 (+134)** across this session
block (continuation of prior 285 → 332 pass).

## Commits this block

| Commit | Scope |
|---|---|
| `47eca266` | load_clips/load_clip_entry V13 SELECT + state_hash V13 cols + 32 sequence-INSERT kind=nested |
| `4b43009a` | Clip.load V13 SELECT + ripple_layout/test_env helpers V13 |
| `3f226dc9` | schema_version 8→9 + load_master_clips V13 + 30 Sequence.create kind + 37 inline kind literals |
| `80ac1a7c` | 5-arg Sequence.create rewrite (10 files) + bulk master_clip_id→nested_sequence_id (51 files) |
| `45c2af54` | strip stray `kind` from frame_rate arg + add kind/audio_rate to opts (20 files) |
| `e3c61eed` | Clip.create positional → V13 table (53 sites / 21 files) |
| `1213b053` | Clip.create positional round 2 (concat-name forms; 25 sites / 16 files) |
| `3bfd534f` | command_helper apply_mutations / restore_deleted_clip / capture+restore V13 |
| `2b8cdffe` | bulk migration — V8 INSERT INTO clips → V13 + master sequence setup + strftime literal (87 files) |

| `65d1fa6e` | "mc_test" → Sequence.ensure_master injection (15 files) |
| `10bb9ce3` | clip_mutator.load_track_clips V13 + mc_test setup hardening |
| `d994a305` | clip_mutator.load_clip_for_duplicate_plan V13 + drop clip_kind='timeline' guard |
| `abc1b56a` | clip_mutator clone_state + plan_insert + resolve_ripple right_clip — V13 fields |
| `746769f5` | rename body refs master_clip_id → nested_sequence_id (20 files) |

| `eae2b688` | inject MC_TEST setup for tests with bare Clip.create (5 files) |
| `3d25646e` | set_parameter Insert/Overwrite V8 → V13 names (17 files) |
| `168b09f9` | V8 INSERT INTO clips → V13 round-2 (7 more files) |
| `6926a38d` | V8 INSERT INTO clips with NULL media_id → V13 placeholder master (18 files) |
| `4a087802` | V8 INSERT INTO clips without media_id column → V13 placeholder (12 files) |
| `5e25f414` | V8 INSERT INTO clips inside Lua heredoc → V13 + INSERT OR IGNORE (4 files) |
| `7af3249a` | hand-fix `]]))` heredoc termination + inject `name` value (2 files) |
| `0f592496` | Insert/Overwrite track_id → target_video_track_id (scoped, 23 files) |
| `62afd3cc` | Insert/Overwrite clip_id → nested_sequence_id (scoped, 7 files) |

Total: **23 commits** (this session block) + 4 from prior block, ~280 test files touched, ~5500 lines changed.

## Architectural changes

### `database.load_clips` / `load_clip_entry`
SELECTs V13 schema: owner+nested seq joins, `media_refs`+`media` transitive
join (only when nested kind='master'). Returns V13 fields (nested_sequence_id,
master_layer_track_id, master_audio_track_id, fps_mismatch_policy, owner_rate,
track_type) + transitional compat surfaces:
- `clip_kind` ← derived from track type ('VIDEO'→'video','AUDIO'→'audio')
- `media_id`/`media_name`/`media_path`/`offline_note` ← media_refs+media join
- `master_clip_id` ← alias for `nested_sequence_id`

Compat surfaces let UI consumers (timeline_view_renderer, project_browser,
timeline_panel, media_relink_dialog) keep functioning unchanged. They are
intended to be removed once those consumers migrate to V13 names.

### `Clip.load` (load_internal)
Same V13 SELECT shape as `database.load_clips`. `load_masterclip_stream` is
now a no-op stub: V13 master sequences hold media_refs, not clips, so the
pre-013 IS-a alias has no analogue.

### `database.load_master_clips`
SELECTs `kind='master'` sequences with media_refs+media join. Replaces V8
join-through-stream-clip pattern.

### `command_state.calculate_state_hash`
Clips queries (scoped + full project) updated to V13 columns.

### Schema version bumped 8 → 9 (matches schema.sql).

### `tests/helpers/ripple_layout.lua` rebuilt
- One master sequence per media via `Sequence.ensure_master` (TC=0 metadata
  synthesized at media creation time).
- Clips emit V13 column names + required NOT-NULL fields (fps_mismatch_policy,
  volume, playhead_frame).

### `tests/test_env.create_test_masterclip_sequence`
Now wraps `Sequence.ensure_master` (media_id required; synthesizes TC=0
metadata when start_tc_value is absent — synthetic /tmp paths have no real
file to extract from).

## Bulk migrations applied (mechanical, deterministic)

1. **32 files**: `INSERT INTO sequences (...)` without `kind` → kind='nested'
   added at column-list and values-list positions.
2. **37 files**: inline `kind = "timeline"` → `"nested"`,
   `kind = "masterclip"` → `"master"`.
3. **30 files**: `Sequence.create` opts table without `kind` → kind='nested'.
4. **10 files**: 5-arg `Sequence.create("name", proj, {merged-opts}, W, H)`
   pattern — split merged opts back into proper frame_rate (3rd) + opts (6th).
5. **20 files**: cleanup pass — strip stray `kind` from frame_rate, add
   `audio_rate=48000` to opts when missing.
6. **12 files**: re-add `kind` to 6th-arg opts where prior cleanup dropped it.
7. **51 files**: bulk rename `master_clip_id =` → `nested_sequence_id =`.
8. **21 + 16 files**: legacy `Clip.create("name", media_id, opts):save(...)`
   → V13 `Clip.create({ name = ..., V13 fields })` table form. Drop V8
   columns (clip_kind, fps_numerator, fps_denominator, media_id, offline);
   inject defaults (fps_mismatch_policy='resample', volume=1.0, playhead_frame=0,
   enabled=1).

Migration scripts live in `/tmp/migrate_*.lua` and `/tmp/migrate_*.py` —
discard after one-shot use; not checked into the repo.

## `command_helper.lua` mutation pipeline — partial V13 migration

`apply_mutations` / `restore_deleted_clip` INSERTs now emit V13 column lists.
`capture_clip_state` snapshots carry V13 fields plus V8 aliases for JSON
round-trip. `restore_clip_state` switches the create-path to V13
`Clip.create({...})` table form.

UPDATE statements in `apply_mutations` were not rewritten this pass — they
already only touch fields that exist in V13 (track_id, timeline_start_frame,
duration_frames, source_in_frame, source_out_frame, enabled). bulk_shift
SQL was not rewritten — it only touches timeline_start_frame which is
schema-stable across V8/V13.

## `clip_mutator.lua` partial V13 migration

`load_track_clips` and `load_clip_for_duplicate_plan` SELECTs migrated to V13
schema (owner+nested seq joins, media_refs join). Returned rows expose V13
fields plus compat surfaces. `clone_state`, `plan_insert` mutation entry, and
`resolve_ripple` right_clip carry V13 fields alongside V8 aliases for JSON
round-trip + apply_mutations transitional acceptance.

Drop of `clip_kind='timeline'` guard in `plan_duplicate_block` — V13 has no
clip_kind column; every clip is a sequence reference (master/still/gap
collapsed into nested refs).

## What's still failing (191 / 657)

| Bucket | Count | Pattern | Resolution |
|---|---|---|---|
| INV-4 violations | 13 | Clip references master sequence too short to hold its source window | Per-test fixture: extend media duration or reduce clip source bounds |
| Missing nested_sequence_id | 11 | V8 tests passed `media_id` but never had master_clip_id; rename didn't cover them | Per-test: create master via `Sequence.ensure_master`, pass id |
| Insert command V8 args | 11 | Tests pass `track_id`, `insert_time`, `advance_playhead`, `source_out` | Per-test rewrite to V13 spec args (target_video_track_id, timeline_start_frame, etc.); Insert vs AddClipsToSequence distinction |
| Sequence.load: id required | 5 | Command receiving nil sequence_id from upstream test setup | Per-test |
| Overwrite V8 args | 3 | Same shape as Insert | Per-test |
| Raw INSERT INTO clips | ~30 | V8 column lists with clip_kind/media_id/fps_numerator/etc. | Per-test rewrite: create master sequence, INSERT V13 cols (owner_sequence_id, nested_sequence_id, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) |
| `command_helper` mutation pipeline | many | apply_mutations / revert_mutations still emit V8 column INSERTs | Foundational — affects 12 commands (cut, paste, batch_ripple_edit, duplicate_clips, lift_range, extract_range, ripple_delete_selection, nudge, rename_item, move_clip_to_track, toggle_clip_enabled, delete_master_clip). Unmigrated. |

### Foundational work still ahead

1. **`command_helper.lua` V13 mutation pipeline** — biggest remaining piece
   of architecture work. Affects all V8-style commands.
2. **UI consumers** — timeline_view_renderer, project_browser, timeline_panel,
   media_relink_dialog still read compat surfaces (clip.media_id,
   clip.clip_kind, clip.master_clip_id). Should migrate to nested_sequence_id
   + nested_sequence resolution.
3. **Phase 3.8 importer V13 emission** (DRP / FCP7 / prproj clip-emit paths)
   + T073b drop-mode classification (FR-025).
4. **Phase 3.9** renderer/inspector pull surfaces.
5. **Phase 3.10** playback/export wiring (T093/T094).
6. **Phase 3.11** 14 acceptance scenario integration tests.
7. **Phase 3.12** banned-id guard sweep.

## NOW
1. `command_helper.lua` V13 mutation pipeline rewrite — unblocks ~50 tests
   that exercise commands beyond Insert/Overwrite.
2. Hand-fix the ~30 raw INSERT-INTO-clips tests via either per-test setup or
   a generic `test_env.create_master_for_media(media_id)` helper.
3. UI consumer migration (timeline_view_renderer.lua first — it reads
   clip.media_id / clip.offline / clip.media_path).
