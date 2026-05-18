# Contract: `core/clip_position` — DRY accessor for clip source positions

**Phase**: 1 — Design
**Status**: Complete
**Module**: `src/lua/core/clip_position.lua` (NEW)
**Spec ref**: FR-009a, FR-001, FR-013, FR-014, FR-016, FR-017
**Implements**: the only legal read/write API for `clips.source_in_frame`, `source_out_frame`, `source_in_subframe`, `source_out_subframe`.

---

## Purpose

Every importer, edit command, resolver, and other reader/writer of clip source positions goes through this module. Direct field access on clip rows (`clip.source_in_frame = ...`) is forbidden outside this module. This:

1. Makes the schema-level audio-vs-video distinction (data-model.md INV-3) structurally impossible to violate at the call site — the accessor refuses on miscategorized calls.
2. Gives the INV-3 / INV-4 / FR-024 enforcement a single chokepoint to audit.
3. Eliminates the contradictory-conventions bug class this whole feature exists to fix.
4. Keeps every consumer DRY — sample↔(frame, subframe) conversion lives in one place, not scattered across importers and edit commands.

## Public API

All functions are pure Lua, take and return Lua tables/numbers, and never touch the database directly. The clip table argument is the loaded in-memory clip object (the same shape `database.load_clips` produces). Writes mutate the in-memory clip; the caller is responsible for the subsequent DB UPDATE through the existing `apply_mutations` pathway.

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
-- Asserts (every call): clip.track_type == 'AUDIO',
--   frame_in/frame_out integer >= 0 (per existing clip-coord policy),
--   0 <= subframe_in < ticks_per_frame,
--   0 <= subframe_out < ticks_per_frame,
--   source_in_frame <= source_out_frame (existing invariant),
--   source sequence and project both loadable from db handle.
clip_position.write_audio_source(clip, db,
    frame_in, subframe_in, frame_out, subframe_out)

-- VIDEO clip: write two components.
-- Asserts: clip.track_type == 'VIDEO',
--   frame_in/frame_out integer >= 0, source_in_frame <= source_out_frame.
-- Subframe columns remain NULL on the in-memory row.
clip_position.write_video_source(clip, frame_in, frame_out)
```

### Helpers (sample ↔ (frame, subframe))

These wrap `subframe_math` (separate contract) with the contextual values pulled from the db so callers don't have to thread `master_clock_hz` / `source_seq.fps_num/den` / `file_rate` themselves.

```lua
-- Convert a file-natural sample position into the unified (frame, subframe)
-- representation for a given clip's source sequence and a specific
-- media_ref's audio sample rate. Asserts on every NSF invariant of the
-- math primitive (see subframe_math.md).
local frame, subframe = clip_position.samples_to_frame_subframe(
    clip, db, media_ref_audio_sample_rate, file_sample_position)

-- Inverse: (frame, subframe) → file_sample position. Used by the resolver.
local file_sample = clip_position.frame_subframe_to_samples(
    clip, db, media_ref_audio_sample_rate, frame, subframe)
```

### Subframe-defaulting for frame-only call sites (FR-013)

Edit commands that create new audio clips (Insert, Overwrite) default subframe to zero — today's mark UX is frame-aligned. The accessor exposes a one-liner so call sites don't reach into the math primitive for "subframe = 0":

```lua
-- Equivalent to write_audio_source(clip, db, frame_in, 0, frame_out, 0)
-- but asserts that the call is intentional (caller passes `:frame_aligned()`
-- explicitly rather than supplying `nil` for subframe).
clip_position.write_audio_source_frame_aligned(clip, db, frame_in, frame_out)
```

## Preconditions and assertions

| Function | Precondition asserted |
|---|---|
| `read_audio_source` | `clip.track_type == 'AUDIO'`; both subframe columns non-NULL; `0 <= sub < ticks_per_frame` (defense-in-depth — the schema guarantees this, the accessor asserts on read as a tripwire). |
| `read_video_source` | `clip.track_type == 'VIDEO'`; both subframe columns NULL. |
| `write_audio_source` | `clip.track_type == 'AUDIO'`; all four args integer; subframes in valid range; `frame_in <= frame_out`. |
| `write_video_source` | `clip.track_type == 'VIDEO'`; args integer; `frame_in <= frame_out`. |
| `samples_to_frame_subframe` | All NSF rules from `subframe_math` apply (positive rates, non-negative samples, integer values, etc.). |
| `frame_subframe_to_samples` | Same. |

Assertion failure messages include the function name, the clip id, and the offending value(s) — Constitution VI requirement.

## Forbidden patterns (caller-side; verified by chokepoint test)

```lua
-- ALL of these are violations. The grep-style test (FR-009a guard)
-- fails the suite if any non-clip_position module hits these patterns.
clip.source_in_frame = ...
clip.source_out_frame = ...
clip.source_in_subframe = ...
clip.source_out_subframe = ...
db:exec("UPDATE clips SET source_in_frame = ...")  -- raw SQL writes
```

Reads (`local x = clip.source_in_frame`) are forbidden outside `clip_position` AND `core/database.lua` (the load path). Database read is required to populate the in-memory table; everything downstream goes through the accessor.

The chokepoint test (`test_clip_position_accessor_chokepoint.lua`) is a static guard:

```lua
-- Scans src/lua/ for forbidden patterns; asserts the only matches are
-- inside src/lua/core/clip_position.lua and src/lua/core/database.lua.
```

## Algorithmic style (Constitution 2.5)

Each function reads as one short algorithm. Per-component assertions are extracted into a named helper `assert_audio_subframe(clip, db, subframe)`, so the public functions stay focused on the "what" (read, write, convert) and delegate the "how" of bound-checking.

## NSF audit

| Half | Coverage |
|---|---|
| 1. Input validation | Every public function asserts on every input (clip kind, integer-ness, range, sign). |
| 2. Output invariants | Writes leave the clip table in a state that satisfies INV-3 + INV-4 by construction (the assert blocks fire before any field is mutated; the write is atomic on success). Round-trip helpers (`samples_to_frame_subframe` ↔ `frame_subframe_to_samples`) are tested for round-trip exactness on divisor rates and bounded error on non-divisor rates (FR-019, FR-021). |

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
| `tests/test_resolver_subframe.lua` | Write via `write_audio_source`, resolve through `frame_subframe_to_samples`, assert file_sample matches (FR-021). |
| `tests/test_subframe_invariants.lua` | Every assert path enumerated in this contract. |

---

*Contract complete.*
