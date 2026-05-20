# Contract: `OpenSequenceInSourceMonitor`

**Spec source**: FR-018 | **Dispatched by**: browser default Return on media-sequence entries (FR-021); browser Opt+Return on clip-sequence entries (FR-022); MatchFrame command flow (already routes to source_viewer.load_*).

## SPEC.args

```lua
{
    sequence_id = { required = true, kind = "string" },  -- any sequence kind: 'master' (will be 'media' post-020) or 'sequence' (will be 'clip')
    project_id  = { required = true, kind = "string" },
}
```

`undoable = false`. View-state change.

## Executor

1. Resolve `source_viewer` via `require("ui.source_viewer")`.
2. Call `source_viewer.load_sequence(args.sequence_id)`. (`load_master_clip` is a one-session alias to this — see plan.md Complexity Tracking.)
3. Return `{ success = true }`.

## Mode entered

`source_viewer` enters **staged_sequence** mode. Marks come from sequence row (`sequences.mark_in_frame`, `mark_out_frame`). I/O presses mutate sequence-row marks (existing behavior). Live-bound-mode FRs (FR-013, 016a-f) do not apply.

## Tests (in `tests/test_browser_activation_routes_through_commands.lua` + `tests/test_source_viewer_publishes_selection.lua` extension)

- Happy path: dispatch with a media-sequence id → source_viewer in staged mode; selection_hub publishes `item_type="sequence"`.
- Happy path: dispatch with a clip-sequence id → same staged-mode entry; clip-sequence inspectable in inspector.
- `undoable = false` verified.
- Precondition: missing `sequence_id` → command_manager rejects.
