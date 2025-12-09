# Timebase Migration Log

**Status:** Active
**Branch:** `timebase-rational-migration-attempt-4`

This document tracks the renaming and type changes of core data models during the transition from Floating-Point Milliseconds to Rational Time (Frames).

---

## 1. Domain Models (Lua)

### **Clip (`src/lua/models/clip.lua`)**

| Old Property | New Property | Old Type | New Type | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `start_value` | **`timeline_start`** | `number` (float ms) | `Rational` | Absolute position on parent timeline. |
| `duration_value` / `duration` | **`duration`** | `number` (float ms) | `Rational` | Length of the clip. |
| `source_in_value` / `source_in` | **`source_in`** | `number` (float ms) | `Rational` | In-point in source media. |
| `source_out_value` / `source_out` | **`source_out`** | `number` (float ms) | `Rational` | Out-point in source media. |
| `timebase_rate` | **`rate`** | `number` (float fps) | `Table` | `{fps_numerator, fps_denominator}` |

### **Sequence (`src/lua/models/sequence.lua`)**

| Old Property | New Property | Old Type | New Type | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `frame_rate` | **`frame_rate`** | `number` (float) | `Rational` | Sequence timebase (e.g. 24/1). |
| `viewport_start_value` | **`viewport_start_time`** | `number` (float ms) | `Rational` | Viewport start position. |
| `viewport_duration_frames_value` | **`viewport_duration`** | `number` (float ms) | `Rational` | Viewport length (duration). |
| `playhead_value` | **`playhead_position`** | `number` (float ms) | `Rational` | Current playhead position. |
| `mark_in_value` | **`mark_in`** | `number` (float ms) | `Rational` | I/O Range In. |
| `mark_out_value` | **`mark_out`** | `number` (float ms) | `Rational` | I/O Range Out. |

---

## 2. Database Schema (Future)

*Note: These changes are PLANNED for Phase 4. Currently using adapters.*

| Table | Old Column | New Column | Type |
| :--- | :--- | :--- | :--- |
| `clips` | `start_value` | `timeline_start_frame` | INTEGER |
| `clips` | `duration_value` | `duration_frames` | INTEGER |
| `clips` | `source_in_value` | `source_in_frame` | INTEGER |
| `clips` | `source_out_value` | `source_out_frame` | INTEGER |
| `clips` | `timebase_rate` | `fps_numerator` | INTEGER |
| `clips` | (None) | `fps_denominator` | INTEGER |

---

## 3. Deprecated Files (To Be Deleted)

*   `src/lua/core/frame_utils.lua` (Replaced by `rational.lua`)
*   `test_ripple_operations.lua` (Mock test, invalid)