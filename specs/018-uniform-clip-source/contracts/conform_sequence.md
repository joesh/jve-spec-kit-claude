# Contract: `ConformSequence` command

**Phase**: 1 — Design
**Status**: Complete
**Module**: `src/lua/core/commands/conform_sequence.lua` (NEW)
**Spec ref**: FR-029, FR-031, FR-032, FR-035
**Implements**: the only legal path to mutate `sequences.fps_numerator` / `sequences.fps_denominator` post-creation.

---

## Purpose

Rewrite a single sequence's `fps` plus every dependent row (media_refs inside this sequence, clips contained in this sequence, clips elsewhere pointing AT this sequence) so the resolver produces the same wall-clock content under the new fps as it did under the old. Atomic, undoable, fails the whole transaction on any per-row failure.

This is the **only** legal path to change `sequences.fps_*`. Direct UPDATEs are blocked by trigger INV-5 (data-model.md). Importers and edit commands that detect an fps drift call `ConformSequence` rather than UPDATEing directly.

## Command signature

Registered with `command_manager` per Constitution II (Command-Driven Interface):

```lua
local SPEC = {
    name = "ConformSequence",
    undoable = true,
    persisted = { ... },
    params = {
        sequence_id   = { type = "string", required = true },
        fps_numerator = { type = "integer", required = true, min = 1 },
        fps_denominator = { type = "integer", required = true, min = 1 },
    },
    execute = function(args, ctx) ... end,
    undo = function(args, ctx) ... end,
    redo = function(args, ctx) ... end,
}
```

No UI (Clarification Q1); invokable from scripts and tests only. The persisted-state shape captures pre-conform `(fps_num, fps_den)` for the sequence plus per-row pre-values for every rewritten media_ref and clip. Undo reverses the rewrite atomically.

## Behavior (transactional)

Single SQLite transaction. Pseudo-algorithm (Constitution 2.5 — algorithm-style):

```
execute(args, ctx):
    seq = load_sequence(args.sequence_id)
    assert(seq.fps_num != args.fps_numerator OR seq.fps_den != args.fps_denominator,
           "ConformSequence: new fps equals old fps; no-op rejected")

    BEGIN TRANSACTION
        CREATE TEMP TABLE _conform_sequence_in_progress (sequence_id TEXT);
        INSERT INTO _conform_sequence_in_progress VALUES (seq.id);

        rewrite_this_sequence_fps(seq, new_fps)
        rewrite_internals_for_kind(seq, new_fps)  -- master OR sequence
        rewrite_outer_clips_pointing_at(seq, new_fps)

        DROP TABLE _conform_sequence_in_progress;
    COMMIT
```

### Per-kind internal rewrite

```
rewrite_internals_for_kind(seq, new_fps):
    if seq.kind == 'master':
        for each media_ref WHERE owner_sequence_id = seq.id:
            scale_in_master_frames(media_ref, old_fps, new_fps)
    elif seq.kind == 'sequence':
        for each clip WHERE owner_sequence_id = seq.id:
            scale_in_owner_frames(clip, old_fps, new_fps)
```

For `kind='master'`, each media_ref's `sequence_start_frame` and `duration_frames` (in master-frames) rescale by `new_fps / old_fps`:
```
new_sequence_start_frame = round(old_sequence_start_frame * new_fps_num * old_fps_den
                                / (new_fps_den * old_fps_num))
new_duration_frames      = round(old_duration_frames * new_fps_num * old_fps_den
                                / (new_fps_den * old_fps_num))
```
`media_ref.source_in` (file-natural samples) is unchanged — the file content didn't change, only the master frame in which we project it.

For `kind='sequence'`, each contained clip's `sequence_start_frame` and `duration_frames` rescale identically. (`source_in_frame`/`source_out_frame` — which point at this clip's OWN source sequence — are independent of this sequence's fps and untouched here. They're handled in the outer-rewrite pass below if THIS sequence is itself somebody else's source.)

### Outer-clip rewrite (BOTH kinds)

```
rewrite_outer_clips_pointing_at(seq, new_fps):
    for each clip WHERE sequence_id = seq.id:  -- clips that USE seq as their source
        rescale_source_frames(clip, old_fps, new_fps)
```

For each clip whose source sequence is the conformed seq:
```
new_source_in_frame  = round(old_source_in_frame  * new_fps_num * old_fps_den
                            / (new_fps_den * old_fps_num))
new_source_out_frame = round(old_source_out_frame * new_fps_num * old_fps_den
                            / (new_fps_den * old_fps_num))
```

**Subframe values are unchanged** by an fps-only conform. Subframes are in master-clock ticks, which are project-wide and fps-independent. Only the integer-frame component rescales. Video clips have no subframe (NULL columns; INV-3 forbids).

### Atomicity (FR-029)

All UPDATEs run inside the single transaction. Any per-row assertion failure or trigger ABORT rolls back the whole transaction; the sequence stays at `(old_fps_num, old_fps_den)` and every dependent row is unchanged.

### Crash recovery (Clarification Q3)

Process crash anywhere in the transaction → SQLite WAL rolls back on next open. The temp table `_conform_sequence_in_progress` dies with the connection; INV-5 re-arms automatically. No banner, no recovery marker, no prompt — the user sees the project as it was pre-conform. Defense-in-depth: invariant triggers INV-3 / INV-4 / INV-5 catch any half-written row at the first subsequent touch.

## Pre/post invariants

| Invariant | Before | After |
|---|---|---|
| `seq.fps_num/den` | `(old_num, old_den)` | `(args.fps_numerator, args.fps_denominator)`. |
| Wall-clock duration of each rewritten media_ref / clip (in seconds) | `t_old` | `t_new == t_old`, within rounding (≤0.5 frame of new fps). |
| Wall-clock placement of each rewritten clip | `(start_old, dur_old)` | `(start_new, dur_new)` represents the same start instant and the same duration in wall-clock seconds, within rounding. |
| Subframe values on all clips (any clip in the project pointing at seq) | `s_old` | `s_new == s_old` exactly. |
| `media_ref.source_in` (file-natural samples) on rewritten media_refs | `samples_old` | `samples_new == samples_old`. |

## Undo / redo (FR-035)

`undo`:
1. Open transaction, set `_conform_sequence_in_progress` flag.
2. Rewrite every persisted row back to its pre-conform value.
3. Set sequence's fps back to pre-conform `(old_num, old_den)`.
4. Drop flag, commit.

`redo`: re-runs `execute`'s rewrite using the persisted post-values.

Per Constitution III, the test `test_conform_sequence.lua` (FR-035) verifies the full round-trip: execute → state-A; undo → state-pre-conform identical to before execute; redo → state-A identical again.

## Tests (`test_conform_sequence.lua`, FR-035)

Two scenarios per the spec:

**(a) `kind='master'`** — master with mixed V+A media_refs, three regular sequences each containing two clips pointing at the master. Conform master from 24/1 to 23.976. Assert:
- Each media_ref's `sequence_start_frame`/`duration_frames` rescale.
- `media_ref.source_in` (file samples) unchanged.
- Each outer clip's `source_in_frame`/`source_out_frame` rescale.
- Each outer clip's `source_in_subframe`/`source_out_subframe` unchanged exactly.
- Resolver at pre-conform timeline_position-in-wall-clock returns same content as post-conform timeline_position-in-wall-clock (within rounding bound).

**(b) `kind='sequence'`** — regular sequence containing five clips; one outer clip in another sequence points at this sequence. Conform this sequence from 30/1 to 24/1. Assert:
- Contained clips' `sequence_start_frame`/`duration_frames` rescale.
- Outer clip's `source_in_frame`/`source_out_frame` rescale.
- All `source_*_subframe` unchanged.

**(c) Atomic rollback on injected failure** — wrap one of the UPDATEs to raise mid-transaction. Assert the entire sequence row + every dependent row reads identical to pre-conform state.

**(d) INV-5 enforcement** — attempt a direct `UPDATE sequences SET fps_numerator = ...` from outside `ConformSequence`; assert the trigger fires with the INV-5 message.

## Performance (Research R4)

Target: <500 ms p95 on a 10k-clip project. Confirmed by back-of-envelope and a 1k-clip smoke test in `test_conform_sequence.lua`. Optional perf test (`test_conform_sequence_perf.lua`) at 10k clips, excluded from default `make -j4`.

## NSF audit

| Half | Coverage |
|---|---|
| 1. Input validation | Assert `sequence_id` exists; new `(num, den)` ≠ old; both new values positive integers. |
| 2. Output invariants | Wall-clock-equivalence assertions in the test, per-row trigger enforcement during execution, atomic transaction guarantees on failure. |

---

*Contract complete.*
