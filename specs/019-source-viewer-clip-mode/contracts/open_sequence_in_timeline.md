# Contract: `OpenSequenceInTimeline`

**Spec source**: FR-019 | **Dispatched by**: browser default Return on clip-sequence entries (FR-021).

## SPEC.args

```lua
{
    sequence_id = { required = true, kind = "string" },  -- must be a clip-sequence kind (was 'sequence' pre-020, 'clip' post-020)
    project_id  = { required = true, kind = "string" },
}
```

`undoable = false`.

## Executor

1. Resolve `timeline_panel` via the existing module path.
2. Call `timeline_panel.load_sequence(args.sequence_id)` (existing API, unchanged by 019 — only the call site moves from `project_browser.activate_item` into this command).
3. Call `focus_manager.focus_panel("timeline")`.
4. Return `{ success = true }`.

## What this command does NOT do

- Does NOT accept a media-sequence (`kind='master'`) — those go to the source viewer. The browser router (`activate_item`) discriminates by item.type before dispatching; this command trusts the caller.
- Does NOT mutate any model state.

## Tests (in `tests/test_browser_activation_routes_through_commands.lua`)

- Happy path: dispatch with a clip-sequence id → timeline_panel.load_sequence called, timeline focused.
- `undoable = false` verified.
