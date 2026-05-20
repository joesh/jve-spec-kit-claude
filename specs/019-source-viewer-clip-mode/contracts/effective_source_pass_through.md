# Contract: `effective_source` amendment (cross-spec)

**Spec source**: FR-016d + spec.md ## Cross-spec touches §015 | **Amends**: 015-source-in-timeline `effective_source` contract

## Current contract (pre-019)

`effective_source.get()` returns a single `source_sequence_id : string | nil`. `effective_source.resolve_for_edit(rec_id, cmd_name)` returns either that id or a structured `problem` table. Marks for Insert/Overwrite come from the `sequences` row of the returned id (`mark_in_frame`, `mark_out_frame`).

## Amended contract (post-019)

When `_source_viewer_seq_id` was set via the live-bound-clip path, the module ALSO carries `(in, out)` overrides:

```lua
-- New internal state (alongside _source_viewer_seq_id):
local _source_viewer_in  = nil  -- integer | nil
local _source_viewer_out = nil  -- integer | nil

-- get() return shape extended:
--   when no overrides: returns seq_id (legacy shape, unchanged)
--   when overrides present: returns seq_id, in, out
function M.get()
    -- ... existing precedence rule (browser-active wins) ...
    return _source_viewer_seq_id, _source_viewer_in, _source_viewer_out
end
```

## Population

When `source_viewer.load_clip(clip_id)` enters live-bound mode, it ALSO calls:
```lua
effective_source._set_source_viewer_clip(clip.sequence_id, clip.source_in_frame, clip.source_out_frame)
```
(or equivalent — exact module entry point name TBD in implementation; what matters is that the override channel is single-writer.)

When `source_viewer.load_sequence(seq_id)` enters staged mode (or unload clears), the overrides are nil and `get()` returns just the seq_id.

## Consumer change

`command_manager.execute_interactive` (or wherever `source_sequence_id` is currently injected for Insert/Overwrite) gains companion injection for `source_in_frame` / `source_out_frame` when the overrides are non-nil. Insert/Overwrite SPEC.args grow `source_in`/`source_out` optional fields; when present, they're consumed verbatim, ignoring any `sequences.mark_in_frame`/`mark_out_frame` on the underlying source sequence.

## Browser-active-wins precedence: unchanged

015's precedence rule still applies — if `project_browser` is the active panel with an insertable selection, that wins. Live-bound source-viewer overrides only flow when the source viewer is the effective source (rule 2 fallthrough).

## Mutation discipline

The three internal fields `_source_viewer_seq_id`, `_source_viewer_in`, `_source_viewer_out` are mutated through three documented entry points (one per direction); writes go through these only:

- **Live-bound entry**: `_set_source_viewer_clip(seq_id, in, out)` — asserts all three args non-nil; `in` and `out` are integers; `out > in`. Writes all three fields in one pass.
- **Staged entry**: `_set_source_viewer_sequence(seq_id)` — writes `_source_viewer_seq_id = seq_id`, `_source_viewer_in = nil`, `_source_viewer_out = nil`.
- **Clear** (unload): `_clear_source_viewer()` — writes all three to nil.

(An earlier draft mandated a defensive `get()` assert validating an atomicity invariant — dropped 2026-05-19 as paranoia. The three entry points are the only writers; a buggy future caller bypassing them is the same shape as any other "developer wrote bad code" failure mode and surfaces through the regular Lua error path.)

## Tests

- `tests/test_effective_source.lua` (EXISTING — EXTEND): new test cases for the override channel:
  - `_set_source_viewer_clip(seq, in, out)` then `get()` returns the triple.
  - `_set_source_viewer_sequence(seq)` (staged) then `get()` returns just seq (in/out nil).
  - `_clear_source_viewer()` then `get()` returns nil.
  - Browser-active-wins: when browser active and live-bound source viewer set, browser selection wins (overrides ignored — browser's own marks apply).
- Insert/Overwrite integration test (NEW) — exercise live-bound source → Insert into record timeline → assert inserted clip has `source_in`/`source_out` equal to the live-bound clip's values (NOT the source sequence's `mark_in_frame`/`mark_out_frame`).
