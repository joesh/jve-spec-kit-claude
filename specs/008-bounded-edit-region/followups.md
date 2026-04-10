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

### FU-2: Sequence generation counter (T012)

**Current state (after 008):** Not implemented. `test_sequence_generation.lua` fails.

**Target:** Add `mutation_generation INTEGER NOT NULL DEFAULT 0` column to `sequences`. `Sequence.increment_generation(id)` bumps it. Enables O(1) staleness detection for nested sequence references.

**Why deferred:** Schema version bump from 6 → 7 requires the schema migration system, which is currently a stub (`database.SCHEMA_VERSION` gate with no migration logic). See `memory/todo_sqlite_strict_integer.md` area.

**Perf cost of deferring:** Zero. The counter is infrastructure for the nested-sequences feature which doesn't exist yet.

**Blocker:** Schema migration system (V6 → V7 migration stub → real migration code). Can land after the migration system is built, or it can bundle with the migration feature itself.

---

### FU-3: 13 pre-existing ripple test failures

**Current state (after 008):** Baseline for 008 was 486 passing, 13 failing. All 13 predate 008.

**Failing files:**
- `test_batch_ripple_concurrent.lua`
- `test_batch_ripple_gap_before_expand.lua`
- `test_batch_ripple_gap_downstream_block.lua`
- `test_batch_ripple_gap_nested_closure.lua`
- `test_batch_ripple_handle_ripple.lua`
- `test_batch_ripple_negative_duration.lua`
- `test_batch_ripple_regressions.lua`
- `test_batch_ripple_retry_limit.lua`
- `test_batch_ripple_upstream_overlap.lua`
- `test_ripple_in_multitrack_upstream_stable.lua`
- `test_ripple_multi_edge_no_false_clamp.lua`
- `test_scoped_gap_recompute.lua` (becomes FU-2 companion; unblocked by T011 but test setup may still need repair)
- `test_sequence_generation.lua` (blocked on FU-2)

**Classification:** Sampled `test_batch_ripple_gap_before_expand` — fails with `expected 2100, got 2500`, last touched by commit `ed29410 gap-as-clip: more test migrations`. These are leftovers from the **feature 005 gap-as-clip refactor** that were never fully updated. Expected values encode assumptions about how gap edges shift downstream clips that no longer match the current (correct-by-regression-guard) implementation.

**Why deferred:** Not blocking 008. Each test needs individual evaluation — test expected value is wrong vs. real regression — and that triage plus per-test fixes don't fit in the 008 scope.

**Action:** Classify each as "test expectation wrong" or "real bug" and track per-file. Joe's "no pre-existing excuse" rule applies but gets a separate task.

**Blocker:** none; independent cleanup work.

---

### FU-4: `test_scoped_gap_recompute` infrastructure repair

**Current state (after 008):** Test was hand-written in an earlier session with wrong APIs (`database.open` instead of `database.init`, `command_manager.init(db, ...)` instead of `(sequence_id, ...)`). Partial repair in commit `972baf0`. Not yet verified to run end-to-end.

**Target:** After T011 (scoped recompute), verify the test exercises the real behavior — that `recompute_gap_clips(affected_track_ids)` only touches the specified tracks' gaps.

**Blocker:** T011 landing (included in 008 Option A').

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

## Pointers for future work

- **FU-1 starting point:** `build_clip_cache` in `src/lua/core/commands/batch_ripple_edit.lua`. Need to know the ripple boundary before load, which means restructuring the pipeline or introducing a two-phase load.
- **FU-2 starting point:** `src/lua/schema.sql:68` (sequences table), `src/lua/models/sequence.lua:114` (`Sequence.load`), `src/lua/core/database.lua:26` (`SCHEMA_VERSION`).
- **FU-3 triage:** run each test, diff expected vs. actual, trace to either outdated assertion or real bug. Do not assume "pre-existing" = "not a real bug."
