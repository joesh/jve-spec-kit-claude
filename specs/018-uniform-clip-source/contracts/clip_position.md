# Contract: `core/clip_position` — DRY accessor for clip source positions

**Phase**: 1 — Design
**Status**: Complete (revised 2026-05-18 — math wrappers dropped per architectural review)
**Module**: `src/lua/core/clip_position.lua`
**Spec ref**: FR-009a, FR-001, FR-013, FR-014, FR-016, FR-017
**Implements**: the only legal API for mutating `clips.source_in_frame`, `source_out_frame`, `source_in_subframe`, `source_out_subframe` on a loaded in-memory clip table.

---

## Purpose

Every edit command and other mutator of in-memory clip source positions goes through this module. Direct field writes (`clip.source_in_frame = ...`) are forbidden outside this module. This:

1. Makes the schema-level audio-vs-video distinction (data-model.md INV-3) structurally impossible to violate at the call site — the accessor refuses on miscategorized calls.
2. Gives the INV-3 / INV-4 enforcement a single chokepoint to audit.
3. Eliminates the contradictory-conventions bug class this whole feature exists to fix.

**Out of scope (revised)**: sample ↔ (frame, subframe) conversion. The 2-line composition (`subframe_math.pack` + `subframe_math.ticks_to_samples`) doesn't earn a wrapper here, and any wrapper that tries inevitably ends up coupling either a DB handle or a `ctx` grab-bag onto a numeric helper — both layer-violating shapes. Callers (resolver, importers, edit commands) compose `subframe_math` directly with the numeric context they already hold (`master_clock_hz`, source seq `fps_num/den`, `mr.audio_sample_rate`).

## Public API

All functions are pure Lua. The clip table argument is the loaded in-memory clip object (the same shape `database.load_clips` produces). Writes mutate the in-memory clip; persistence is the caller's responsibility via the existing `apply_mutations` pathway. No function takes a DB handle or `ctx` table — the only contextual parameter is `tpf` (ticks_per_frame, integer), which the caller derives once via `subframe_math.ticks_per_frame(master_clock_hz, source_fps_num, source_fps_den)`.

Every function asserts on contract violation per Constitution VI (no silent fallbacks, no defaults).

### Reads

```lua
-- AUDIO clip: returns four integers.
-- Asserts: clip exists, clip.track_type == 'AUDIO', subframe columns non-NULL.
local frame_in, subframe_in, frame_out, subframe_out =
    clip_position.read_audio_source(clip)

-- VIDEO clip: returns two integers.
-- Asserts: clip exists, clip.track_type == 'VIDEO', subframe columns are NULL.
local frame_in, frame_out = clip_position.read_video_source(clip)
```

### Writes

```lua
-- AUDIO clip: write all four components atomically.
-- Asserts: clip.track_type == 'AUDIO',
--   tpf > 0 integer,
--   frame_in/frame_out integer,
--   0 <= subframe_in < tpf, 0 <= subframe_out < tpf (subframe_math.assert_canonical),
--   source_in_frame <= source_out_frame.
clip_position.write_audio_source(clip, tpf,
    frame_in, subframe_in, frame_out, subframe_out)

-- VIDEO clip: write two components.
-- Asserts: clip.track_type == 'VIDEO',
--   frame_in/frame_out integer, source_in_frame <= source_out_frame.
-- Subframe columns remain NULL on the in-memory row.
clip_position.write_video_source(clip, frame_in, frame_out)

-- Frame-aligned audio write (FR-013) — subframe = 0 is canonical for any
-- tpf > 0, so no tpf is required. Used by edit commands and importers that
-- write new audio clips on the frame-aligned mark UX.
clip_position.write_audio_source_frame_aligned(clip, frame_in, frame_out)
```

## Preconditions and assertions

| Function | Precondition asserted |
|---|---|
| `read_audio_source` | `clip.track_type == 'AUDIO'`; both subframe columns non-NULL; both frames + subframes integer. Defense-in-depth — the schema guarantees this, the accessor asserts on read as a tripwire. |
| `read_video_source` | `clip.track_type == 'VIDEO'`; both subframe columns NULL; both frames integer. |
| `write_audio_source` | `clip.track_type == 'AUDIO'`; `tpf > 0`; all four position args integer; `0 <= subframe < tpf`; `frame_in <= frame_out`. |
| `write_video_source` | `clip.track_type == 'VIDEO'`; both args integer; `frame_in <= frame_out`. |
| `write_audio_source_frame_aligned` | `clip.track_type == 'AUDIO'`; both args integer; `frame_in <= frame_out`. |

Assertion failure messages include the function name, the clip id, and the offending value(s) — Constitution VI requirement.

## Forbidden patterns (caller-side; verified by chokepoint test)

```lua
-- ALL of these are violations. The grep-style chokepoint test
-- (test_clip_position_accessor_chokepoint.lua, FR-009a) fails the suite if any
-- non-clip_position module hits these patterns.
clip.source_in_frame = ...
clip.source_out_frame = ...
clip.source_in_subframe = ...
clip.source_out_subframe = ...
db:exec("UPDATE clips SET source_in_frame = ...")  -- raw SQL writes
```

Field READS (`local x = clip.source_in_frame`) are allowed inside `clip_position`, `core/database.lua` (the load path), and `models/sequence.lua` (the resolver, which reads loaded rows to compose with `subframe_math`). New `Clip.create` insert paths read field-shaped fields tables — that's the create path, not a read-mutate-write cycle, and is enforced by `Clip._create_v13_row`'s INV-3 assertions.

## Algorithmic style (Constitution 2.5)

Each function reads as one short algorithm: validate clip kind, validate integer-ness + bounds + canonicality, then perform the atomic field write. Common assertions (`assert_clip`, `assert_int`, `assert_bound`) are factored into named helpers so the public functions stay focused on intent.

## NSF audit

| Half | Coverage |
|---|---|
| 1. Input validation | Every public function asserts on every input (clip kind, integer-ness, range, sign, canonicality). |
| 2. Output invariants | Writes leave the clip table in a state that satisfies INV-3 + INV-4 by construction (the assert blocks fire before any field is mutated; the write is atomic on success). |

## Failure modes the contract makes impossible

- A video clip with a non-NULL subframe (caller would have to bypass `write_video_source` AND the schema trigger).
- An audio clip created without subframes (caller would have to bypass `write_audio_source` AND the schema NOT NULL constraint on audio rows AND INV-3).
- A subframe value silently rounded or clamped (asserts fire before any rounding).
- A mid-update partial state (no function writes one column and leaves another inconsistent).

## Tests (pinned)

| Test file | Covers |
|---|---|
| `tests/test_clip_position_accessor_chokepoint.lua` | FR-009a grep guard. |
| `tests/test_subframe_math.lua` | The underlying math (separately specified). |
| `tests/test_clip_subframe_persistence.lua` | Write → save → load → read round-trip (FR-020). |
| `tests/test_resolver_subframe.lua` | Resolver `frame_subframe → file_sample` math (FR-021), composed of `subframe_math` calls in the resolver (no `clip_position` math wrapper). |
| `tests/test_subframe_invariants.lua` | Every assert path enumerated in this contract. |

## Revision history

- **2026-05-18**: dropped `samples_to_frame_subframe`, `frame_subframe_to_samples`, and the `db`/`ctx` parameter on `write_audio_source*` after architectural review. Math wrappers added wrapper layers without abstraction value; `db` parameter coupled the helper to the DB layer. Callers now hold `tpf` and pass it as a numeric argument; sample-tick conversion goes through `subframe_math` directly.

---

*Contract complete.*
