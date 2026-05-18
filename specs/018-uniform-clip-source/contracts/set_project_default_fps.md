# Contract: `SetProjectDefaultFps` command

**Phase**: 1 — Design
**Status**: Complete
**Module**: `src/lua/core/commands/set_project_default_fps.lua` (NEW)
**Spec ref**: FR-030a, FR-026, FR-028, FR-036a

---

## Purpose

Change `projects.settings.default_fps` (the value pre-filled into new-sequence / new-master creation). **Settings-only**: no existing sequence, media_ref, or clip is touched. To actually rewrite an existing sequence's fps, the user invokes `ConformSequence` (separate contract). To prevent confusion, this command's contract is "settings, full stop."

## Command signature

```lua
local SPEC = {
    name = "SetProjectDefaultFps",
    undoable = true,
    persisted = { old_fps_num, old_fps_den, new_fps_num, new_fps_den },
    params = {
        fps_numerator   = { type = "integer", required = true, min = 1 },
        fps_denominator = { type = "integer", required = true, min = 1 },
    },
    execute = function(args, ctx) ... end,
    undo = function(args, ctx) ... end,
    redo = function(args, ctx) ... end,
}
```

No UI in 018 (Clarification Q1).

## Behavior

```
execute(args, ctx):
    project = load_project()
    settings = json_decode(project.settings)
    old = settings.default_fps
    assert(old.num != args.fps_numerator OR old.den != args.fps_denominator,
           "SetProjectDefaultFps: new fps equals current default; no-op rejected")
    settings.default_fps = { num = args.fps_numerator, den = args.fps_denominator }
    UPDATE projects SET settings = json_encode(settings) WHERE id = project.id
```

Single-row UPDATE, no cascade. The trigger INV-6 (master_clock_hz single-writer) does NOT fire because this UPDATE doesn't change `master_clock_hz`.

## Pre/post invariants

| Invariant | Before | After |
|---|---|---|
| `projects.settings.default_fps` | `{num: A, den: B}` | `{num: args.num, den: args.den}`. |
| Every `sequences` row | unchanged | unchanged. |
| Every `media_refs` row | unchanged | unchanged. |
| Every `clips` row | unchanged | unchanged. |

## Undo / redo

`undo`: restore `default_fps` to the persisted `(old_num, old_den)`. `redo`: re-apply `(new_num, new_den)`.

## Tests (`test_set_project_default_fps.lua`, FR-036a)

1. Setup: project with `default_fps = {num: 24, den: 1}` and three existing sequences (one master, two regulars), each with their own fps already set.
2. Run `SetProjectDefaultFps(30, 1)`.
3. Assert: `projects.settings.default_fps == {num: 30, den: 1}`.
4. Assert: every existing sequence's `fps_num/den` unchanged.
5. Assert: every media_ref and clip row hash unchanged.
6. Create a new sequence without specifying fps; assert it pre-fills with `{30, 1}`.
7. Undo; assert `default_fps == {num: 24, den: 1}`.
8. Redo; assert `default_fps == {num: 30, den: 1}`.

Plus invariant test: attempt `SetProjectDefaultFps` with `fps_numerator = 0` → assert rejection with actionable message.

## NSF audit

| Half | Coverage |
|---|---|
| 1. Input validation | Both args positive integers; new ≠ old. |
| 2. Output invariants | Test asserts row counts and hashes for sequences/media_refs/clips tables are pre-/post-identical. |

---

*Contract complete.*
