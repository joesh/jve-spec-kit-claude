# 008 Follow-up Work

Items scoped OUT of the 008 refactor but worth tracking.

## Deferred from 008

### FU-1: Further bound `build_clip_cache` (strict edit region)

**Current state (after 008):** `build_clip_cache` reads ALL tracks' clip indexes from `timeline_state`. In-memory, fast, but not truly bounded.

**Target:** Load only:
1. Clips whose edges are in `edge_infos`
2. Their immediate prev/next neighbors on the same track
3. For multitrack ripple: first downstream clip + upstream on each other track at the boundary

**Why deferred:** Requires pipeline restructuring. Current consumers assume `ctx.all_clips` / `ctx.track_clip_map` contain the whole sequence:
- `inject_implicit_gap_edges` iterates `track_clip_map` across all tracks (pre-boundary discovery)
- `pick_gap_anchor_clip_id` needs arbitrary track clip lists for edge_preview payload
- `compute_neighbor_bounds` scans `all_clips` for arbitrary clips

Bounding further means either refactoring these consumers or adding on-demand `timeline_state.get_*` wrappers.

**Perf cost of deferring:** ~negligible. In-memory iteration over a few hundred clips is microseconds. The 2-second stall was the DB path, which is already gone.

**Blocker:** none; can be done any time as a pure refactor.

---

### FU-2: Sequence generation counter (T012) — **LANDED**

**Status:** Resolved. Dropped the "schema migration system blocker" claim, which was a fiction — the existing version gate already supports the no-backward-compat workflow (re-import from .drp, or one-shot `ALTER TABLE` for in-progress DBs). FU-2 needed ~30 lines across 4 files, not weeks of migration infrastructure.

**What landed:**
- `schema.sql`: `sequences.mutation_generation INTEGER NOT NULL DEFAULT 0` and `schema_version` bumped 6 → 7
- `database.lua`: `M.SCHEMA_VERSION = 7`
- `sequence.lua`: field added to `Sequence.load` return shape, new `Sequence.increment_generation(id)` method
- `command_manager.lua`: bumps the counter **once per user action** on execute, undo, and redo. Single-command paths (`execute`, `M.execute_undo`, `execute_redo_command`) call an `increment_sequence_generation_if_scoped(cmd)` helper; group paths (`M.undo_group`, `M.redo_group`) call `increment_sequence_generations_for_commands(group_cmds)` which de-dupes sequence_ids across group members. The nested-execute path does not bump — the wrapper (Insert/Overwrite) already counts as one action.
- `test_sequence_generation.lua`: setup fixed (populated `created_at`/`modified_at` on projects + all NOT NULL columns on sequences), extended with a negative test for the empty-id assert, and extended with an end-to-end Insert → undo → redo case that asserts the counter bumps to exactly 1 / 2 / 3 (proving the one-bump-per-action contract across wrapper + nested).
- `resources/templates/film_24fps.jvp`: deleted stale V6 template; self-regenerates on next open

**Semantic correction:** An earlier draft of FU-2 incremented inside `run_undoer` / `run_redo_executor`, which double-counted whenever a wrapper command formed an undo group with a nested child (Insert + AddClipsToSequence → 2 bumps on undo instead of 1). The end-to-end test caught it. The counter now represents "user-visible state transitions", which is what a nested-sequence reference wants: undo rolls the sequence back, but from the reference's point of view the sequence *changed* (one monotonic step), and the cached generation is stale either way.

**Consumer status:** No code reads the counter yet. It's infrastructure for the future nested-sequences feature (a compound clip referencing sub-sequence X can cache X's generation at reference time and compare on next read).

---

### FU-3: 13 "pre-existing" ripple test failures — **RESOLVED** (all green)

I labeled 13 ripple failures "pre-existing" at the start of 008 and carried that label across several cleanup passes without reading the errors. Every single one turned out to be either fixed incidentally by 008's core refactor or caused by 008 itself.

**Disposition:**

| Test | How it resolved |
|--|--|
| `test_batch_ripple_concurrent` | Fixed incidentally by build_clip_cache rewrite to use timeline_state (commit 3180620) |
| `test_batch_ripple_gap_before_expand` | Same |
| `test_batch_ripple_gap_downstream_block` | Same |
| `test_batch_ripple_gap_nested_closure` | Same |
| `test_batch_ripple_handle_ripple` | Same |
| `test_batch_ripple_negative_duration` | Same |
| `test_batch_ripple_retry_limit` | Same |
| `test_batch_ripple_upstream_overlap` | Same |
| `test_ripple_in_multitrack_upstream_stable` | Same |
| `test_batch_ripple_regressions` | 008-caused bug: blocker edge key reported the downstream `:in` instead of the upstream `:out`. Fixed in commit ee16dbf. |
| `test_ripple_multi_edge_no_false_clamp` | 008-caused bug: cross-track propagation delta used the sum of all seeds on the anchor track instead of the per-edge delta. Fixed in commit ee16dbf. |
| `test_scoped_gap_recompute` | Infrastructure repair (API fixes) in 972baf0 + T011 scoped recompute. |
| `test_sequence_generation` | FU-2 landed — see above. |

**Lesson:** The "pre-existing" label is an anti-pattern. It was already in my auto-memory as `feedback_no_preexisting_excuse.md`, and I reinforced it during this session after Joe had to explicitly say "there are ripple tests failing" to get me to read the errors.

---

### FU-4: `test_scoped_gap_recompute` infrastructure repair — **RESOLVED**

Test setup used wrong APIs (`database.open`, `command_manager.init(db, …)`). Repaired during the initial TDD rewrite (972baf0) — correct APIs, proper NOT NULL column population on project + sequence seeding. T011 then turned the test green.

---

### FU-5: Overlap trigger — **LANDED** as commit 2a549fc

**Status:** Resolved via option 2 variant (no new column needed — exploited the non-overlap invariant with existing index).

**Approach delivered:** Rewrote `trg_prevent_video_overlap_{insert,update}` to check only the two nearest neighbors (upstream + downstream) via index seeks on `idx_clips_track_start`, rather than scanning all clips on the track with an `EXISTS` subquery. O(log N) per row instead of O(N).

**Measured on anamnesis (same fixture as pre-FU-5):**

- Raw per-id UPDATE on 976 video clips: **62.7ms → 5.9ms (10x)**
- Single WHERE UPDATE on 976 video clips: **56.3ms → 3.6ms (15x)**
- Full BatchRippleEdit on V1 start: **118.1ms → 63.0ms (1.9x)**

Pipeline perf improvement is smaller than the SQL win because the remaining budget is distributed overhead in command_manager (state hashing ~15ms/command, command save, undo tree bookkeeping). Those are pre-existing costs unrelated to 008.

**Original 008 + FU-5 combined impact:** 2000ms → 63ms (**32x**).

**Edge case handled:** Negative `timeline_start_frame` (pre-roll clips) previously broke the upstream check because `coalesce(NULL, 0) > -100` returned true. Fixed by coalescing to `NEW.timeline_start_frame` so "no upstream" resolves to the adjacent case regardless of sign.

---

### FU-7: content_changed triggers redundant full clip reload — NEW

**Symptom:** BatchRippleEdit (and every other sequence-scoped command)
currently does carefully-targeted in-memory mutation via `__timeline_mutations`
→ `apply_command_mutations` → `clip_state.apply_mutations`, then immediately
fires `Signals.emit("content_changed", seq_id)`, which triggers
`playback_engine:notify_content_changed()` → `PLAYBACK.RELOAD_ALL_CLIPS(pc)`.
The C++ controller throws away its entire prefetch window and re-fetches
every clip in range via the clip provider callback (which hits SQLite).

The surgical Lua-side update is preserved in `clip_state` (timeline view
reads from there), but the C++ playback side does the brute-force reload
anyway — defeating a large fraction of the 008 + FU-5 engineering win on
the playback path.

**Evidence:** the FU-6 profile accounts for ~52ms of BatchRippleEdit's
107ms undo (22.5ms SQL + 30ms state hash × 2). The remaining ~55ms is
unattributed. Unmeasured hypothesis: most of it is the two
`RELOAD_ALL_CLIPS` hits on `content_changed` (one from `sequence_monitor`,
one from `playback_engine` itself — both handlers fire on the same signal
and both call `notify_content_changed` on the same engine).

**Observed double subscription:**
- `src/lua/ui/sequence_monitor.lua:122` — `Signals.connect("content_changed", ...)` → `self.engine:notify_content_changed()`
- `src/lua/core/playback/playback_engine.lua:383` — `Signals.connect("content_changed", ...)` → `engine:notify_content_changed()`

These two handlers fire on the same signal and call the same method on
the same engine. One of them is redundant.

**Mitigations to explore:**

1. **Carry mutations through the signal.** Change emit shape to
   `content_changed(seq_id, mutations)` (`mutations` optional, `nil`
   = legacy "reload everything" semantics). Playback handler applies
   mutations targetedly to its cached prefetch window mirroring what
   `clip_state.apply_mutations` does on the Lua side. Fall back to
   `RELOAD_ALL_CLIPS` only when mutations are nil or the shape is
   beyond incremental (structural changes outside the prefetch range).

2. **Defer RELOAD_ALL_CLIPS during playback.** If the user is parked,
   the next frame-fetch will naturally query the provider; no reload
   needed. During active playback, a reload is unavoidable for frames
   that were already prefetched past the mutation point.

3. **Drop the duplicate subscription.** One of sequence_monitor or
   playback_engine should own the content_changed handler, not both.

**Blocker:** none. Pure Lua + optional C++ API extension for incremental
mutation application.

**Why deferred:** Outside 008 scope. Worth measuring first — add perf
tracking around the two notify_content_changed calls during a ripple
execute/undo cycle on the anamnesis project, then attack whichever of
the three mitigations above gives the most bang for the buck.

---

### FU-6: Further command_manager overhead reduction — NEW

**Current state (after 008 + FU-5):** BatchRippleEdit on anamnesis = ~63ms execute, ~107ms undo, ~115ms redo. Of the 63ms execute:

| Phase | Time | Notes |
|--|--|--|
| `apply_mutations` (SQL, includes bulk_shift) | 22.5ms | Trigger now cheap; cost is per-id UPDATE overhead + connection round-trips |
| `calculate_state_hash` (×2) | 15.2ms | NSF invariant check — reads all 2882 clips twice |
| `<other>` (save, undo tree, UI sync, logs) | ~25ms | Command persistence, `command:save` JSON encode, signal emissions |

**Mitigations to explore:**

1. **Scoped state hash.** `calculate_state_hash` iterates all clips on the sequence to compute a content fingerprint. For commands that only touch a few clips, hashing just the affected tracks (or caching the hash of unchanged tracks) would drop this to <1ms.
2. **Lazy command JSON encode.** `command:save` JSON-encodes `bulk_shifts` (which contains the captured `clip_ids` arrays — up to thousands of UUIDs). Defer this to background or use a binary format.
3. **Skip state hash when suppress_if_unchanged is false.** The NSF check is a safety net; for commands with a clear mutation signal, it's redundant.

**Blocker:** none. This is pure `command_manager` / `command.lua` work.

**Why deferred:** Outside 008 scope. 008 + FU-5 delivered 32x improvement and the <16ms target is no longer the ceiling of a single component — it's scattered across many small overheads in the command framework. Hitting it requires a separate focused pass.

---

### FU-5 original entry (for history; see above for resolution):

**Current state (after 008):** Measured on the anamnesis project (20 tracks, 2882 media clips, 598 gap clips). Ripple at start of V1 (~975 downstream clips on that track alone):

| Pipeline phase | Time | Notes |
|--|--|--|
| `build_clip_cache` | 0.6ms | Was the 2s stall pre-008 — fixed |
| `prime_neighbor_bounds_cache` | 1.1ms | |
| `compute_constraints` | 0.9ms | |
| `inject_implicit_gap_edges` | 1.2ms | |
| `compute_downstream_shifts` | 0.4ms | |
| `build_planned_mutations` | <0.1ms | |
| `timeline_state.apply_mutations` (UI + scoped gap recompute) | 3.8ms | T011 scoped recompute working |
| `command_helper.apply_mutations` (SQL) | **85.8ms** | 65% of total |
| **Total execute** | **~132ms** | |

Raw-SQL isolation benchmarks confirm the SQL cost is structural:

- Per-id `UPDATE` on 1227 audio clips (no trigger): 15.5ms = 0.013ms/row
- Per-id `UPDATE` on 976 video clips (overlap trigger): 62.7ms = 0.064ms/row
- Single `WHERE`-clause `UPDATE` on 976 video clips: 56.3ms (same — trigger fires per-row regardless of statement shape)

**Diagnosis:** `trg_prevent_video_overlap_update` runs an `EXISTS` subquery per row that is effectively O(N) because the second overlap condition `(c.timeline_start_frame + c.duration_frames) > NEW.timeline_start_frame` can't be answered by the `(track_id, timeline_start_frame)` index alone — `c.duration_frames` isn't in the index. Bulk-shifting N video clips on one track is therefore O(N²). For N≈1000, that's ~60ms — a hard floor under the current schema.

**Mitigations to explore:**

1. **Drop + recreate the trigger around `BatchRippleEdit` bulk_shift.** Fragile but effective. The Lua pipeline already validates overlaps before committing, so the trigger is a safety net for *other* code paths; we can safely skip it here.
2. **Make the trigger O(log N).** Add `timeline_end_frame` as a generated column on `clips` with an index, then rewrite the trigger to use it for range overlap detection via the index. Schema migration required.
3. **Two-pass `UPDATE` with parking offset.** Tried during 008 — does NOT help because the trigger fires per-row in both passes, doubling the cost.
4. **Single `UPDATE ... WHERE`.** Tried — same trigger cost, also trips the trigger mid-statement on video tracks unless processed in DESC order (which SQLite doesn't guarantee without `ORDER BY` on `UPDATE`, a non-default compile option).

**Perf baseline delivered by 008:** 2000ms → 120ms (17x improvement). The <16ms aspirational target from the spec is not achievable until FU-5 lands.

**Blocker:** none; independent work. Recommended approach = option 2 (generated column + index) for long-term correctness. Option 1 is a pragmatic interim fix.

---

## Pointers for future work (remaining open items)

- **FU-1 (further bound `build_clip_cache`):** starting point is `build_clip_cache` in `src/lua/core/commands/batch_ripple_edit.lua`. The current implementation reads all tracks from timeline_state (in-memory, fast). Strict "only load edit region + neighbors" needs the ripple boundary known before load, which means restructuring the pipeline or introducing a two-phase load. Marginal perf gain vs effort; deferred indefinitely.
- **FU-6 (command_manager overhead reduction):** see the breakdown in the FU-6 section above — state hashing (~15ms/command) + command save + undo tree bookkeeping are the new ceiling. No single dominant target.

## Playback-subsystem test failures triaged during 008 cleanup (unrelated to 008)

During the sixth cleanup pass we discovered five integration tests failing on master. The 008 branch touched zero playback code (only commit `6704b8d` touched EMP, and that was peak_gen, not decode). Investigation outcome:

**Fixed in this pass (stale test data, no production code changes):**
- `test_playback_gap_clears_and_recovers.lua`: `pool_threads = 2` → `3`. Commit `02452f1` (SPEED_DETECT isolation) tightened the minimum pool size from 2 to 3 (1 prep + 1 video + 1 audio) but didn't update this test.
- `test_codec_status_on_startup.lua`: (a) Seeded `error_code = "Unsupported"` → `"DecodeFailed"`. Commit `f245d26` legitimately strips stale `Unsupported` entries from the persisted cache on load (codec support can change between builds); `DecodeFailed` is persistent. (b) Clips moved from positions 0/60/120 to 1000/1060/1120 so none sit under the default playhead, preventing `renderer.get_video_frame` from calling `update_from_tmb` and overwriting the seeded cache with the real probe result (BRAW SDK `FileNotFound` for fake BRAW content). (c) Assertion rewritten to read `media_status.get(path)` directly instead of inspecting clip.offline/error_code after rendering — tests the actual regression ("load_persisted runs before first paint") without racing the async bg probe worker.
- `test_editor_operations.lua`: Hardcoded sequence UUID `f29d6d6a-...` and track UUIDs no longer exist after the anamnesis project was re-imported from DRP. Replaced with runtime lookup: gold-master sequence picked by `MAX(clip_count) ORDER BY modified_at DESC`; track IDs resolved via `(sequence_id, track_type, track_index)` which is stable across re-imports.

**Unresolved — real playback-subsystem bugs, need a focused session:**
- `test_tmb_qtrle_stride.lua`: Sync decode returns `has_frame=0` for every frame past frame 0 on a 4K QTRLE clip. `deliverFrame` log trace shows seek delivers one frame, then every subsequent play tick gets nothing from `TMB_GET_VIDEO_FRAME`. This is a real decoder-pipeline regression — the test previously caught a `stride=4` SPEED_DETECT bug, but the symptom is now worse (zero unique frames, not one-in-four). Candidate regressions: `02452f1` (SPEED_DETECT isolation), `4b6b58e` (SPEED_DETECT storm fix), `9de4cbb` (reader pool eviction). Bisect needed.
- `test_tmb_same_file_two_tracks.lua`: Passes standalone (10/10 distinct source PTS) but fails in batch_playback (7/10, V2 repeats the first frame). Batch contamination from a preceding test leaking reader/cache state. The batch runner runs 12 tests in a single process — shared EMP global state between tests.
- `test_playback_av_sync.lua`: Flaky drift threshold. Max A/V drift oscillates around the 350ms limit (observed 300–548ms across runs), and p95 oscillates around the 150ms p95 limit. Under CPU load the test fails; on an idle machine it passes. The test's thresholds were tuned on a specific machine; they need either (a) wider tolerance for manual-TICK jitter or (b) a stable CPU-budget harness.

**Recommendation:** ship 008 with these three tests still failing. They are pre-existing, documented, and would derail any narrow branch to fix properly. A separate branch should: (1) bisect the qtrle regression to a specific commit, (2) add state isolation between batch tests (per-test EMP reset), (3) re-tune av_sync thresholds or add a CPU-load gate.
