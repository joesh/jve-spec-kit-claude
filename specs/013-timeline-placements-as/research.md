# Phase 0 Research: Timeline Placements as Nested Sequence References

**Feature**: 013-timeline-placements-as
**Date**: 2026-04-23

Five open questions from plan.md Phase 0, resolved.

---

## 1. Row-type separation

**Decision**: Split today's `clips` table into two tables, distinguished by structural kind:

- **`media_refs`** (NEW): track-positioned references to media files. Each row belongs to a `kind='master'` sequence and holds `media_id` + `source_in/out_frame` in the media file's native units.
- **`clips`** (existing name, semantics narrow): track-positioned references to other sequences. Each row belongs to a `kind='nested'` (non-master) sequence and holds `nested_sequence_id` + `source_in/out_frame` in the referenced sequence's timebase.

Today's `clips.clip_kind` discriminator is removed; the table a row lives in IS its type.

**Rationale**:
- **Static type safety** (rule 2.21). A `media_refs` row and a `clips` row share some plumbing columns but hold fundamentally different references with different `source_in/out_frame` units. One table with a discriminator means `source_in_frame` silently means different things depending on `clip_kind`; every reader has to remember which. Separate tables make the type unambiguous.
- **Column overloading** is the worst class of this kind of bug. A file's frame count vs a nested sequence's frame count aren't interchangeable; the schema should not pretend they're the same column.
- **User-model alignment**. Clips (things on a non-master sequence's track) and media_refs (things inside a master) are different user-level concepts. Collapsing them was a code-organization convenience, not a domain reflection.

**Alternatives considered**:
- *One table + discriminator column + DB CHECK constraint*: catches "wrong reference field set" but not "read source_in_frame without knowing unit." Weaker than the types-are-tables approach.
- *View-based union*: adds SQL indirection for no behavioral gain.

---

## 2. Override state storage

**Decision**: Two dedicated sparse tables, plus one nullable column on `clips`.

- `clip_channel_override(clip_id, channel_index, enabled, gain_db, PRIMARY KEY (clip_id, channel_index))`. Row exists only when the editor has explicitly set that channel's state on that clip. Absent row = inherit nested sequence's channel state.
- `clips.master_layer_track_id` (nullable column on `clips`). NULL = inherit nested sequence's `default_video_layer_track_id`.
- `media_refs_channel_state(owner_sequence_id, channel_index, enabled, default_gain_db, PRIMARY KEY (owner_sequence_id, channel_index))`: master-level channel state that tracking clips inherit.

**Rationale**:
- **FR-020 mandates one undo per override change.** Row-per-channel INSERT/UPDATE/DELETE maps trivially to a command_manager action with a descriptive label. A JSON blob would require diff-based undo, which the command_manager doesn't natively support.
- **Query pattern at playback time**: the resolver joins `clips` with `clip_channel_override` in one query; missing rows implicitly mean "inherit from the nested sequence," with master-level state reached by one more level of resolution.
- **Revert-override is one row delete** — `DELETE FROM clip_channel_override WHERE clip_id=? AND channel_index=?`. Atomic and undoable; removal re-enables inheritance for that channel without bookkeeping.
- **Layer override as a single column** on `clips` is appropriate for a one-cardinality relationship. NULL denotes inheritance; INV-8 guarantees the chain resolves.

**Alternatives considered**:
- *JSON blob on the clip row*: simpler DDL, but requires parsing on every resolution, complicates per-channel undo, and violates FR-020.
- *Embed in `clip_links`*: conflates link-group identity with override state; link groups and overrides are orthogonal.

---

## 3. Cycle detection algorithm

**Decision**: Depth-first traversal at mutation time, uncached. Before creating or modifying any `clips` row (any command that would point a clip at a nested sequence), walk the candidate target's reachable sequence set; refuse if the candidate's owning sequence appears in that set.

```text
function would_create_cycle(owner_seq_id, candidate_target_id):
    visited = {}
    stack = [candidate_target_id]
    while stack not empty:
        cur = stack.pop()
        if cur == owner_seq_id: return true
        if cur in visited: continue
        visited[cur] = true
        for each clip K in sequence cur:
            stack.push(K.nested_sequence_id)
    return false
```

**Rationale**:
- **Correctness dominates performance at mutation time.** Mutation frequency is human-paced; traversal cost is O(|reachable nested sequences from candidate|). Real projects rarely exceed depth 3.
- **Caching transitive closure** requires invalidation on every content change inside any sequence — likely net negative unless profiling shows mutation latency is a problem.
- **At playback/resolve time**, the resolver assumes the DAG is valid (mutation check already ran) and tracks a `recursing_into` set during a single resolve call to assert loudly on any cycle. Defense in depth against DB corruption or external mutation.

**Alternatives considered**:
- *Cached transitive closure table*: invalidation correctness is harder than the traversal it saves.
- *No mutation-time check, rely only on playback-time depth cap*: violates FR-010's "refuse to create" semantic and permits silent DB corruption.

---

## 4. Layer selector encoding + FK behavior on track deletion

**Decision**:
- Store `master_layer_track_id` (FK to `tracks.id`) as a nullable column on `clips`. NULL = inherit the referenced sequence's `default_video_layer_track_id`.
- FK behavior on deletion of the referenced track: `ON DELETE SET NULL`. Per-clip override gracefully reverts to the referenced sequence's default.
- The referenced sequence's own `default_video_layer_track_id` follows INV-8: non-NULL whenever that sequence has at least one video track. If the sequence's default-layer target is deleted, a command must set a new valid value or refuse the track deletion.

**Rationale**:
- `track_id` is stable under reordering, satisfying FR-016.
- `ON DELETE SET NULL` on the clip column matches the intent: the override is an optional interpretation; if its target disappears, fall back to the referenced sequence's default (which INV-8 guarantees is valid).
- For the referenced sequence's default-layer target: an invalid default IS an error and surfaces via FR-022's loud-fail.

**Alternatives considered**:
- *Hard FK (no `ON DELETE` action)*: blocks track deletion while any clip overrides it. Too strict.
- *`ON DELETE CASCADE`*: deletes the clip itself. Surprising data loss.
- *Store `track_index`*: violates FR-016.

---

## 5. Resolver signature + override application order

**Decision**: Single Lua-side resolver:

```lua
Sequence:resolve_in_range(seq_id, start_frame, end_frame, context)
  → list of { media_path, source_in, source_out, timeline_start, track_role, volume, effects, provenance }
```

`context` carries resolution-scoped state: `recursing_into` set, `depth`, `export_mode` (does not alter resolution output), `project_fps_mismatch_policy`.

**Dispatch by kind**:
- `sequences[seq_id].kind='master'` → iterate `media_refs`, emit leaf `ResolvedEntry` rows.
- `sequences[seq_id].kind='nested'` → iterate `clips`, recurse.

**Override application order during clip recursion**:
1. **Layer selector** — filter the nested sequence's V tracks to the clip's `master_layer_track_id` (or its `default_video_layer_track_id`). Audio passes unfiltered.
2. **Recurse** into `clip.nested_sequence_id` with the clamped range and filtered track set.
3. **Channel state** — on returned audio results, join with `clip_channel_override` for `(clip.id, channel_index)`; apply if present, else inherit.
4. **Gain composition** — multiply clip's volume × inherited volume × any leaf media_ref volume through the chain.

Reversing the order (channel state before layer selection) would apply channel mutes to tracks the layer filter then discards — incorrect.

**Rationale**:
- **One code path** for playback and export (FR-019). The `context` parameter carries caller-specific policy without forking the traversal.
- **Resolver is pure** — given `(seq_id, range, context, DB state)`, output is deterministic. Facilitates caching, testing, and parallel consumers.
- **Cycle safety** via `recursing_into` set: O(1) cycle check per recursion step, asserts loudly if mutation-time check missed something.
- **Provenance field** on each output carries the chain of row IDs — answers "why does this frame come from this file?" without re-traversing.

**Alternatives considered**:
- *Separate video and audio functions*: today's `get_video_in_range` / `get_audio_in_range`. Keep as thin wrappers around `resolve_in_range` for incremental migration, retire once callers are migrated.
- *Move resolution to C++*: costs reactivity and testability. Keep in Lua.
- *Apply overrides on the referenced sequence directly*: violates the "referenced sequence is an undifferentiated source" invariant.

---

## Summary

All five questions resolved. No [NEEDS CLARIFICATION] markers remain.

| # | Question | Decision |
|---|---|---|
| 1 | Row-type separation | Two tables (`media_refs`, `clips`); `clip_kind` discriminator removed |
| 2 | Override state | Sparse `clip_channel_override` rows + nullable `master_layer_track_id` column |
| 3 | Cycle detection | Uncached mutation-time DFS + defense-in-depth assert at resolve time |
| 4 | Layer selector + FK | `track_id` reference; `ON DELETE SET NULL` for per-clip override; loud-fail for referenced sequence's own default |
| 5 | Resolver signature | Unified `Sequence:resolve_in_range`; override order layer → channel → gain |
