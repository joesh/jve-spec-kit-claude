# JVE Rational Time Math Library Specification

**Status:** APPROVED
**Target File:** `src/lua/core/rational.lua`
**Goal:** Provide a robust, immutable, integer-based time object.

---

## 1. Data Structure

```lua
--- @class Rational
--- @field frames number (integer) The frame count
--- @field fps_numerator number (integer) Frames Per Second (Numerator)
--- @field fps_denominator number (integer) Frames Per Second (Denominator)
local Rational = {
    frames = 0,
    fps_numerator = 1,
    fps_denominator = 1
}
```

---

## 2. Constructors

*   **`Rational.new(frames, fps_numerator, [fps_denominator])`**
    *   Creates a new Rational time.
    *   *Example:* `Rational.new(1001, 30000, 1001)` -> 1001 frames @ 29.97fps.

*   **`Rational.from_seconds(seconds, fps_numerator, [fps_denominator])`**
    *   Converts a float (e.g. `1.5s`) to frames.
    *   `frames = floor(seconds * (num / den) + 0.5)`

---

## 3. Core Operations

*   **`Rational:rescale(target_fps_num, target_fps_den)`**
    *   Returns a *new* Rational converted to the target rate.
    *   *Math:* `new_frames = (old_frames * target_fps_num * old_fps_den) / (old_fps_num * target_fps_den)`

*   **`Rational:add(other)`**
    *   Returns `self + other`.
    *   If rates match: `Rational.new(self.frames + other.frames, self.rate)`
    *   If rates differ: Rescales `other` to `self`'s rate, then adds.

*   **`Rational:sub(other)`**
    *   Returns `self - other`.

*   **`Rational:compare(other)`**
    *   Returns `-1`, `0`, `1`.
    *   Cross-multiplication comparison.

---

## 4. Utility Functions

*   **`Rational:to_seconds()`**
    *   Returns `frames / (fps_numerator / fps_denominator)`. (Float).

*   **`Rational:to_timecode(drop_frame)`**
    *   Generates SMPTE HH:MM:SS:FF string.
    *   Must handle 29.97 Drop-Frame vs Non-Drop-Frame logic.

---

## 5. Lua Implementation Details
*   Use Metatables for `__add`, `__sub`, `__eq`, `__tostring`.
*   Strict type checking: Throw error if `frames` is not an integer.