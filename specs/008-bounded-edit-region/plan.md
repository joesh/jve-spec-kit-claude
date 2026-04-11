# Implementation Plan: Bounded Edit Region

**Branch**: `008-bounded-edit-region` | **Date**: 2026-04-09 | **Spec**: [spec.md](spec.md)

## Status (2026-04-10)

Landed in full: components 1, 2, 3 + FU-5 (trigger rewrite). The
"schema migration blocker" that initially deferred component 3 was
a fiction on my part — the existing version gate already supports
the no-backward-compat workflow and component 3 needed ~30 lines
of straightforward code. Landed as FU-2 in this branch.

Perf impact on anamnesis (20 tracks, 2882 clips, worst-case V1 ripple):

  execute  2000ms → 38ms   (~53x)
  undo     n/a   → 39ms
  redo     n/a   → 39ms

Remaining gap vs the `<16ms` aspirational target is distributed
overhead in command_manager (state hashing, command save, UI sync) —
documented as FU-6 in [followups.md](followups.md).

Follow-up ledger: see [followups.md](followups.md) for FU-1 through
FU-6.

## Summary

Edit operations currently scan all clips on all tracks. This plan introduces a bounded edit region invariant: operations examine only the clips participating in the edit. Downstream shifts become a bulk per-track operation with one max-shift check. Gap special-casing is removed (gaps are clips). Gap recomputation is scoped to affected tracks.

## Technical Context
**Language/Version**: Lua (LuaJIT) + C++ (Qt6)  
**Primary Dependencies**: command_manager, batch_ripple_edit, timeline_state, gap_lifecycle  
**Storage**: SQLite (.jvp project files)  
**Testing**: LuaJIT test harness, `make -j4`  
**Target Platform**: macOS (Darwin)  
**Project Type**: Single (desktop video editor)  
**Performance Goals**: Roll edit O(2 clips + neighbors); ripple O(edit region) + O(1 per track)  
**Constraints**: No fallbacks, fail-fast asserts, no backward compatibility  
**Scale/Scope**: 20+ track sequences, hundreds of clips per sequence

## Constitution Check

**I. Modular Architecture**: Pass — bounded clip set is a standalone module; scoped gap recompute is a parameter addition  
**II. Command-Driven Interface**: Pass — integrates into existing command_manager execute flow  
**III. Test-First Development**: Pass — TDD: tests for bounded access, max-shift check, gap-as-clip constraints  
**IV. Documentation-Driven Specifications**: Pass — this plan  
**V. Template-Based Consistency**: Pass — follows existing command/mutation patterns  
**VI. Fail-Fast Assert Policy**: Pass — bounds enforced by asserts  
**VII. No Fallbacks or Default Values**: Pass — no fallback to full recomputation  
**VIII. No Backward Compatibility**: Pass — old per-clip downstream path replaced, not shimmed  

## Project Structure

### Source Code (affected files)
```
src/lua/
  core/
    commands/
      batch_ripple_edit.lua      — bounded build_clip_cache, remove gap special-casing,
                                   replace per-clip downstream with bulk shift + max-shift check
    ripple/batch/
      pipeline.lua               — no change (steps already correct if cache is bounded)
    gap_lifecycle.lua            — no change (already per-track)
    timeline_active_region.lua   — no change (snapshot already scoped)
  models/
    sequence.lua                 — mutation_generation counter
  ui/timeline/
    state/
      timeline_core_state.lua    — scoped recompute_gap_clips
      clip_state.lua             — propagate affected_track_ids from mutations
    timeline_state.lua           — pass affected_track_ids to recompute_gap_clips

tests/
  test_bounded_edit_region.lua       — bounded access invariant tests
  test_max_shift_check.lua           — multi-track max-shift computation tests
  test_scoped_gap_recompute.lua      — gap recompute scoping tests
  test_sequence_generation.lua       — generation counter tests
```

## Phase 0: Research

Complete — see [research.md](research.md).

## Phase 1: Design

### Key Insight: Two Distinct Scopes

An edit has two scopes with fundamentally different needs:

1. **Edit region** — the directly edited clips and their neighbors. `compute_shift_bounds` applies here because multi-edge selections can squeeze intermediate clips/gaps. Gaps participate as clips (the gap-as-clip abstraction holds).

2. **Downstream block** — everything after the edit region on affected tracks. Shifts as one opaque unit by a uniform delta. No per-clip constraint checking needed. The only constraint is one number: the **max allowable shift** = minimum available space at the boundary across all affected tracks.

The current code conflates these two scopes: it feeds downstream clips into `compute_shift_bounds` (per-clip constraint checking for clips that all shift by the same amount) and special-cases gaps throughout (`clip_kind ~= "gap"` in `collect_downstream_clips`, excluded from `prime_neighbor_bounds_cache`). This breaks the gap-as-clip abstraction and creates O(all clips) work for an O(edit region) operation.

### Component 1: Scoped Pipeline (batch_ripple_edit.lua)

**Edit region scope:**
- `build_clip_cache` loads only the edited clips + their immediate neighbors (including gaps — no special-casing)
- `prime_neighbor_bounds_cache` includes gaps (they constrain multi-edge edits)
- `compute_shift_bounds` runs only on the edit region clips — never on downstream
- `inject_implicit_gap_edges` checks boundary position on other tracks — one lookup per track

**Downstream scope:**
- Replaced by a single **max shift check**: for each affected track, compute the space between the last non-shifting clip and the first shifting clip at the boundary. The minimum across all tracks is the max allowable shift. One number, one pass.
- Downstream mutation is a **bulk shift per track**: `UPDATE clips SET timeline_start = timeline_start + delta WHERE track_id = ? AND timeline_start >= boundary`. No per-clip enumeration.
- `collect_downstream_clips` and per-clip downstream shift logic are eliminated.

**Gap abstraction restored:**
- Remove all `clip_kind ~= "gap"` checks from the pipeline
- Gaps participate in neighbor bounds, constraints, edge injection — same as media clips

### Component 2: Scoped Gap Recomputation (timeline_core_state.lua)

`recompute_gap_clips` gains an optional `affected_track_ids` parameter:

```
recompute_gap_clips(affected_track_ids)
  if not affected_track_ids:
    -- FULL recompute (init/load only)
    strip all gaps, recompute all tracks
  else:
    -- SCOPED recompute
    strip gaps ONLY on affected tracks
    recompute gaps ONLY on affected tracks
    leave other tracks' gaps untouched
```

**Propagation**: `__timeline_mutations` already contains `track_id` per update and `track_id` per bulk_shift. `clip_state.apply_mutations` collects affected track IDs and returns them. `timeline_state.apply_mutations` passes them to `recompute_gap_clips`.

### Component 3: Sequence Generation Counter (sequence.lua)

Schema column (added inline in the `sequences` CREATE TABLE, not via
ALTER — per rule 2.15 we don't maintain backward compat; stale DBs are
re-imported or one-shot patched):

```sql
mutation_generation INTEGER NOT NULL DEFAULT 0
```

`command_manager` bumps the counter once per user-visible action on the
target sequence — on execute, undo, and redo. Group actions (wrapper
commands like Insert + nested AddClipsToSequence) dedupe by sequence_id
so a single group advances the counter exactly once. Readable via
`Sequence.load(id).mutation_generation`. Used by future nested sequence
pre-condition checks: "is the nested sequence still at the generation
I expect?" See [followups.md FU-2](followups.md#fu-2-sequence-generation-counter-t012--landed)
for the full landing record.

### Data Model Changes

**sequences table**: Add `mutation_generation INTEGER NOT NULL DEFAULT 0`

**__timeline_mutations format** (simplified bulk_shifts):
```lua
{
  sequence_id = "...",
  updates = { { clip_id, start_value, duration_value, source_in_value, source_out_value, track_id } },
  deletes = { clip_id, ... },
  inserts = { { full clip record }, ... },
  bulk_shifts = { { track_id, shift_frames, start_frame } },
  -- affected_track_ids derived at apply time, not persisted
}
```

### What Gets Removed

- `collect_downstream_clips` — replaced by per-track bulk shift
- Per-clip `compute_shift_bounds` on downstream clips — replaced by per-track max shift check
- `clip_kind ~= "gap"` checks in `prime_neighbor_bounds_cache`, `collect_downstream_clips`, `build_clip_cache`
- `bulk_shift_anchor_clips`, `bulk_shift_anchor_lookup` — downstream handled uniformly
- `track_clip_positions` — never read by anything

## Phase 2: Task Planning Approach

**Strategy**: TDD order. Tests first, then implementation.

1. **Tests for max shift check** — multi-track scenarios with varying gap sizes at boundary, verify correct max shift computed
2. **Tests for gap-as-clip in constraints** — multi-edge selection with gaps between, verify gaps constrain properly
3. **Max shift check** — one pass through affected tracks, compute available space at boundary
4. **Bounded build_clip_cache** — load only edit region clips + neighbors, gaps included
5. **Remove gap special-casing** — `prime_neighbor_bounds_cache` includes gaps, no `clip_kind` checks
6. **Bulk downstream shift** — per-track SQL update replaces per-clip enumeration
7. **Scoped recompute_gap_clips** — accept affected_track_ids parameter
8. **Mutation track propagation** — clip_state returns affected tracks, timeline_state forwards
9. **Remove dead code** — `collect_downstream_clips`, `bulk_shift_anchor_*`, `track_clip_positions`
10. **Sequence generation counter** — schema + model + increment logic
11. **Integration validation** — verify with real project, measure edit timing

**Ordering**: 1-2 parallel (tests first). 3-6 sequential (core refactor). 7-8 parallel. 9-10 independent. 11 last.

**Estimated**: ~11 tasks

## Unresolved Questions

- ~~The bulk downstream shift uses SQL `UPDATE ... WHERE track_id = ? AND
  timeline_start >= boundary`. Does `clip_state.apply_mutations` need a new
  mutation type for this, or can the existing `bulk_shifts` format handle it?~~
  **Resolved in cleanup pass**: the canonical shape
  `{ track_id, shift_frames, start_frame }` now covers both the SQL execute
  and in-memory sync paths. Both legacy forms (`clip_ids`,
  `first_clip_id + anchor_start_frame`) are removed from every producer,
  consumer, test, and the undo hydrator. See `tasks.md` Notes section.
- Multi-edge selection across multiple tracks with different gap sizes at boundaries — does the max shift check need to be per-track (some tracks can shift more than others) or is one global max correct? Currently all tracks shift by the same delta, so one global max is correct. But if we ever support per-track deltas, this needs revisiting.

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete
- [x] Phase 1: Design complete
- [x] Phase 2: Task planning complete
- [x] Phase 3: Tasks generated (see tasks.md)
- [x] Phase 4: Implementation complete (components 1, 2, 3, FU-5)
- [x] Phase 5: Validation passed — anamnesis ripple 38ms p50, test
      suite 500 / 0

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved

**Deferred**: none. Component 3 (sequence generation counter) landed
as FU-2 — see [followups.md](followups.md#fu-2-sequence-generation-counter-t012--landed).
- [x] Complexity deviations documented (none)
