# Contract: `core/subframe_math` — Canonical sub-frame math primitive

**Phase**: 1 — Design
**Status**: Complete
**Module**: `src/lua/core/subframe_math.lua` (NEW)
**Spec ref**: FR-006, FR-007, FR-008
**Implements**: pack/unpack, normalize, samples↔ticks, validate.

---

## Purpose

The single source of truth for arithmetic on `(frame, subframe)` pairs. Every reader and writer of clip source positions consults this module — directly via `clip_position.samples_to_frame_subframe` (the public path), or as the inner kernel of `clip_position`'s own helpers.

The primitive is pure Lua, has zero dependencies (no database, no signals, no model layer), and is the chokepoint for all sample↔(frame, subframe) conversion in the project. By centralizing the math we get:

- One place to verify FR-008's rounding rule (round-half-away-from-zero).
- One place to enforce FR-007's no-silent-fallback policy.
- One place tests can exhaust the (rate × fps × clock) combinatorial space.

## Public API

All functions are pure (no side effects, no I/O). Inputs are Lua numbers; outputs are Lua numbers. The module asserts on every input violation per FR-007 and Constitution VI.

### Tick-per-frame computation

```lua
-- Compute the number of master-clock ticks in one frame of a sequence
-- with the given fps. The result is integer when master_clock_hz is divisible
-- by fps_num/fps_den; otherwise the trigger and the math primitive agree
-- on the floor (and the resulting bound on subframe is the same on both sides).
--
-- Asserts: master_clock_hz > 0 integer; fps_num > 0 integer; fps_den > 0 integer.
local ticks = subframe_math.ticks_per_frame(master_clock_hz, fps_num, fps_den)
```

### Pack and unpack

```lua
-- pack: given (frame, subframe) and the per-frame tick bound, returns a single
-- INTEGER 'total_ticks' value useful for arithmetic. Useful in edit commands
-- that need to add a tick-delta to a position and then re-canonicalize.
--   total = frame * ticks_per_frame + subframe
-- Asserts: 0 <= subframe < ticks_per_frame.
local total_ticks = subframe_math.pack(frame, subframe, ticks_per_frame)

-- unpack: inverse. Given a total_ticks and ticks_per_frame, returns the
-- canonical (frame, subframe).
--   frame = total_ticks // ticks_per_frame
--   subframe = total_ticks % ticks_per_frame
-- Asserts: total_ticks integer >= 0; ticks_per_frame > 0 integer.
local frame, subframe = subframe_math.unpack(total_ticks, ticks_per_frame)
```

`pack` followed by `unpack` is exact for any valid input. This is the foundational round-trip test (FR-019).

### Normalize

```lua
-- Given a possibly out-of-range (frame, subframe) pair, canonicalize into a
-- valid (frame, subframe) where 0 <= subframe < ticks_per_frame.
-- This is the only operation that may take a subframe outside [0, tpf) as
-- INPUT — every other write API asserts canonical form.
-- Negative deltas (subframe < 0) are normalized correctly by carrying borrow.
-- Asserts: ticks_per_frame > 0 integer; frame integer.
local out_frame, out_subframe = subframe_math.normalize(
    frame, subframe, ticks_per_frame)
```

`normalize` is used by edit commands that mutate positions by tick deltas (slip, roll). It is NOT used by clip_position writers — those receive canonical inputs and assert.

### Sample ↔ tick conversion

```lua
-- Convert a file-natural sample count to master-clock ticks given the file's
-- native sample rate.
--   ticks = round_half_away_from_zero(samples * master_clock_hz / file_rate)
-- Asserts: samples integer; file_rate > 0 integer; master_clock_hz > 0 integer.
local ticks = subframe_math.samples_to_ticks(
    samples, file_rate, master_clock_hz)

-- Inverse: ticks → file-natural samples.
--   samples = round_half_away_from_zero(ticks * file_rate / master_clock_hz)
-- Asserts: ticks integer; file_rate > 0 integer; master_clock_hz > 0 integer.
local samples = subframe_math.ticks_to_samples(
    ticks, file_rate, master_clock_hz)
```

Round-trip exactness:

| Combination | Round-trip property |
|---|---|
| `file_rate` divides `master_clock_hz` (e.g. 48k/192k) | EXACT for every integer sample count. |
| `master_clock_hz` divides `file_rate` (rare) | EXACT for every integer tick count. |
| Neither divides the other (e.g. 44.1k/192k) | Error bound: ≤0.5 sample one way, ≤0.5 tick the other way. Tested. |

The shared rounding rule (`round_half_away_from_zero` = `floor(x + 0.5)` for non-negative inputs — subframes and sample positions are non-negative per FR-002 / domain) makes the resolver path and the math primitive agree bit-for-bit, eliminating the off-by-one mismatch class.

### Validation (callable as a tripwire)

```lua
-- Returns true if (frame, subframe) is canonical for the given ticks_per_frame.
-- Calling code is encouraged to assert on this in defensive read paths.
local ok = subframe_math.is_canonical(frame, subframe, ticks_per_frame)

-- Assertion variant. Crashes with a contextual message on violation.
subframe_math.assert_canonical(frame, subframe, ticks_per_frame, "context_str")
```

## NSF audit (FR-007 enumeration)

The module rejects every form of invalid input with a loud assert:

| Invalid input | Assertion |
|---|---|
| Non-integer frame, subframe, ticks_per_frame, samples, ticks | `assert(value == math.floor(value), ...)` |
| Negative frame in `pack` | `assert(frame >= 0, ...)` |
| Negative subframe in `pack` | `assert(subframe >= 0, ...)` |
| `subframe >= ticks_per_frame` in `pack` | `assert(subframe < ticks_per_frame, ...)` |
| Non-positive `master_clock_hz` | `assert(master_clock_hz > 0, ...)` |
| Non-positive `fps_num` or `fps_den` | `assert(... > 0, ...)` |
| Non-positive `file_rate` | `assert(file_rate > 0, ...)` |

Every assertion message names the function, the parameter, and the offending value (Constitution VI).

## Algorithmic style (Constitution 2.5)

Each function is short (≤10 LOC body), single-responsibility, named for what it computes (`pack`, `unpack`, `normalize`, `samples_to_ticks`, `ticks_to_samples`, `ticks_per_frame`, `is_canonical`, `assert_canonical`). The two "round" helpers are extracted into a single private `round_half_away_from_zero(x)` so the rule is named, shared, and trivially modifiable in one place.

## Tests (`test_subframe_math.lua`, FR-019)

The test file exhausts the following grid:

| Dimension | Values tested |
|---|---|
| `master_clock_hz` | 192000 (default), 48000 (alt-config), 44100 (alt-config). |
| Source-seq fps | 24/1, 23.976 (24000/1001), 30/1, 60/1, 25/1. |
| File audio rate | 48000, 96000, 192000, 44100, 88200. |
| `subframe` | 0, 1, `ticks_per_frame - 1`, midpoint. |
| `samples` | 0, 1, large values, frame-boundary samples. |

For each cell:
- `pack`/`unpack` round-trip is exact.
- `samples_to_ticks`/`ticks_to_samples` round-trip is exact for divisor cases, ≤0.5 unit for non-divisor cases.
- `normalize` correctly carries forward (subframe >= tpf) and backward (subframe < 0).
- Every invalid-input assertion fires (using `pcall` and matching the assertion text).

---

*Contract complete.*
