# Contract: `OverwriteTrimEdge`

**Spec source**: FR-014, FR-015 | **Peer**: `RippleTrimEdge` (reused, see `src/lua/core/commands/ripple_trim_edge.lua`)

## SPEC.args

```lua
{
    clip_id      = { required = true, kind = "string" },
    edge         = { required = true, kind = "string" },  -- "left" or "right"
    delta_frames = { required = true, kind = "number" },  -- non-zero integer
    sequence_id  = { required = true, kind = "string" },  -- owner sequence (where the clip lives)
    project_id   = { required = true, kind = "string" },
}
```

`undoable = true`. Own undo entry (NOT delegated to `BatchRippleEdit` — single-row mutation owns its own state capture).

## Executor semantics

1. Assert `args.edge ∈ {"left", "right"}` — message includes function name + bad value.
2. Assert `args.delta_frames ~= 0`.
3. Load clip via `Clip.load(args.clip_id)`; assert non-nil.
4. Compute new `source_in_frame` or `source_out_frame`:
   - `edge == "left"`: `new_source_in = clip.source_in_frame + delta_frames`. `new_sequence_start_frame = clip.sequence_start_frame + delta_frames` (the placement's start shifts to absorb the trim — but downstream clips stay put, leaving a gap if shrinking, an overlap-attempt if growing).
   - `edge == "right"`: `new_source_out = clip.source_out_frame + delta_frames`. `sequence_start_frame` UNCHANGED.
5. Compute `new_duration_frames` consistent with the new source range (on the source-sequence timebase).
6. Assert `new_source_in < new_source_out` (no inverted range).
7. Assert source range fits within the source-sequence content extent (`Sequence:content_duration` of `clip.sequence_id`). No silent clamp.
8. Capture undo state (clip's current `source_in_frame`, `source_out_frame`, `sequence_start_frame`, `duration_frames`).
9. Mutate the clip via `Clip.update_bounds(clip_id, sequence_start, duration, source_in, source_out)` — surgical 4-column UPDATE, not full row save.
10. Report a single-row mutation: set `__timeline_mutations` parameter on the command + emit `sequence_content_changed` for the clip's owner sequence.

## Undoer

Restores the four captured columns to their pre-execute values; emits `__timeline_mutations` for the owner sequence.

## What this command does NOT do

- Does NOT propagate the duration delta to downstream clips (that's `RippleTrimEdge`).
- Does NOT check for overlap with adjacent clips when growing (out of 019 scope; if an overlap would occur, the user's fault — JVE has overlap-resolution machinery elsewhere if needed).
- Does NOT mutate any sequence-row marks.

## Tests (in `tests/test_overwrite_trim_edge.lua`)

Every happy/undo scenario MUST read back the post-mutation state via `Clip.load(args.clip_id)` and assert the four columns (`source_in_frame`, `source_out_frame`, `duration_frames`, `sequence_start_frame`) against expected values — per FR-015b. Asserting only that the command "succeeded" is NOT sufficient (NSF Half-2).

- Happy path: right-edge shrink → clip duration decreases, downstream clips unmoved. Read-back assertions on the four columns.
- Happy path: left-edge shrink → clip starts later (sequence_start_frame moves), downstream clips unmoved. Read-back assertions.
- Happy path: right-edge grow → clip duration increases (asserting no overlap is upstream). Read-back assertions.
- Undo round-trip: capture pre-execute state via `Clip.load`, execute, undo, re-load, assert all four columns equal pre-execute values bit-for-bit (FR-015b).
- Precondition: `delta_frames == 0` → assert.
- Precondition: `edge == "bogus"` → assert.
- Precondition: `clip_id` doesn't exist → assert.
- Precondition: trim out past content extent → assert.
- No-downstream-movement: place a clip at frame 100, downstream clip at frame 200; shrink the first by 50; read back BOTH clips and assert downstream clip still at frame 200 (its row's `sequence_start_frame` unchanged).
