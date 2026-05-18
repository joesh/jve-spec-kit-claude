# Contract: `SetProjectMasterClock` command

**Phase**: 1 — Design
**Status**: Complete
**Module**: `src/lua/core/commands/set_project_master_clock.lua` (NEW)
**Spec ref**: FR-030b, FR-027, FR-028, FR-036b

---

## Purpose

Change `projects.settings.master_clock_hz` and atomically rescale every clip's `source_in_subframe` / `source_out_subframe` so that the wall-clock instant each clip resolves to remains the same under the new clock. Sequence `fps` values are untouched (clock and fps are independent dimensions).

This is the **only** legal path to change `projects.settings.master_clock_hz`. Direct UPDATEs are blocked by trigger INV-6 (data-model.md).

## Command signature

```lua
local SPEC = {
    name = "SetProjectMasterClock",
    undoable = true,
    persisted = { old_clock, new_clock, per_clip_old_subframes },
    params = {
        master_clock_hz = { type = "integer", required = true, min = 1 },
    },
    execute = function(args, ctx) ... end,
    undo = function(args, ctx) ... end,
    redo = function(args, ctx) ... end,
}
```

No UI in 018 (Clarification Q1).

## Behavior (transactional)

```
execute(args, ctx):
    project = load_project()
    settings = json_decode(project.settings)
    old_clock = settings.master_clock_hz
    new_clock = args.master_clock_hz
    assert(old_clock != new_clock,
           "SetProjectMasterClock: new clock equals current; no-op rejected")

    BEGIN TRANSACTION
        CREATE TEMP TABLE _set_master_clock_in_progress (project_id TEXT);
        INSERT INTO _set_master_clock_in_progress VALUES (project.id);

        rescale_every_audio_clip(old_clock, new_clock)
        settings.master_clock_hz = new_clock
        UPDATE projects SET settings = json_encode(settings) WHERE id = project.id

        DROP TABLE _set_master_clock_in_progress;
    COMMIT
```

### Per-clip rescale

```
rescale_every_audio_clip(old_clock, new_clock):
    for each clip WHERE source_in_subframe IS NOT NULL:
        new_in  = round_half_away_from_zero(old.source_in_subframe  * new_clock / old_clock)
        new_out = round_half_away_from_zero(old.source_out_subframe * new_clock / old_clock)
        UPDATE clips SET source_in_subframe = new_in,
                          source_out_subframe = new_out
                    WHERE id = clip.id
```

The rounding follows the shared FR-008 rule (round-half-away-from-zero) so this command and the resolver agree on edge cases.

**Subframe-bound preservation**: after rescale, every new value MUST still satisfy `0 <= subframe < ticks_per_frame(new_clock, source_seq.fps_num, source_seq.fps_den)`. This is preserved by construction:
- Old: `0 <= old_sub < ticks_per_frame(old_clock, ...)` = `old_clock * fps_den / fps_num`.
- Scaled: `new_sub ≈ old_sub * new_clock / old_clock`.
- Max new_sub: `(old_clock * fps_den / fps_num - 1) * new_clock / old_clock` ≈ `new_clock * fps_den / fps_num - new_clock/old_clock` < `new_clock * fps_den / fps_num` = `ticks_per_frame(new_clock, ...)`.

So the rescaled value satisfies INV-4 by construction.

Defense-in-depth: INV-4 fires on the per-row UPDATE during the transaction if the construction proof above is ever wrong (e.g. degenerate edge case at very small clocks). That's the entire point of having the trigger.

### Atomicity (FR-030b)

All UPDATEs (every clip + the projects-settings row) run inside the single transaction. Any per-row trigger failure aborts the whole transaction; subframes and `master_clock_hz` stay at their old values.

### Crash recovery (Clarification Q3)

Process crash mid-transaction → SQLite WAL rolls back. Temp table dies with the connection; INV-6 re-arms. No banner, no recovery marker. Defense-in-depth: INV-4 fires on the first post-rollback subframe write if any half-applied value was somehow persisted.

## Pre/post invariants

| Invariant | Before | After |
|---|---|---|
| `projects.settings.master_clock_hz` | `M_old` | `args.master_clock_hz`. |
| Every audio clip's `source_in_subframe` | `s` | `round(s * M_new / M_old)`. |
| Every audio clip's `source_out_subframe` | `s` | `round(s * M_new / M_old)`. |
| Every audio clip's `source_in_frame` / `source_out_frame` | unchanged | unchanged. |
| Every video clip | unchanged | unchanged. |
| Every sequence's `fps_num/den` | unchanged | unchanged. |
| Every media_ref | unchanged | unchanged. |
| Wall-clock instant each audio clip resolves to | `t` | `t ± round_error`, where round_error ≤ 1/M_new seconds. |

## Undo / redo (FR-036b)

`undo`: restore every clip's `(source_in_subframe, source_out_subframe)` from persisted pre-values; restore `master_clock_hz` to `M_old`. Single atomic transaction with INV-6 flag set.

`redo`: re-applies the new clock + the saved post-values (avoids re-doing the rounding, which is technically idempotent but persisting the post-values eliminates rounding-direction flicker in the unlikely degenerate case).

## Tests (`test_set_project_master_clock.lua`, FR-036b)

1. Setup: project with `master_clock_hz = 192000`; ten audio clips spread across two sequences with various non-zero subframes (including the edge value `ticks_per_frame - 1`); five video clips (NULL subframes).
2. Run `SetProjectMasterClock(48000)`.
3. Assert: `master_clock_hz == 48000`.
4. Assert: each audio clip's subframes scaled by `48000/192000 = 1/4`, rounded half-away-from-zero.
5. Assert: every video clip unchanged (NULL subframes).
6. Assert: every sequence's `fps_num/den` unchanged.
7. Assert: every media_ref unchanged.
8. Undo; assert subframes and clock restored exactly.
9. Redo; assert post-values restored exactly.
10. Inject a per-row failure mid-transaction; assert all rows + clock revert.
11. INV-6 enforcement: attempt direct `UPDATE projects SET settings = ... master_clock_hz changed ...` outside the command; assert trigger fires.

## NSF audit

| Half | Coverage |
|---|---|
| 1. Input validation | `master_clock_hz` positive integer; ≠ current value. |
| 2. Output invariants | Wall-clock-equivalence test; per-row INV-4 enforcement during transaction; atomicity test. |

---

*Contract complete.*
