# JVE Timebase Migration Specification

**Status:** APPROVED (Ready for Implementation)
**Version:** 5.0
**Strategy:** Scorched Earth / Schema-First. No Backward Compatibility.

---

## 1. The Core Philosophy
*   **Frames (Units), not Milliseconds:** Time is strictly a count of units (Frames or Samples) at a specific rate.
*   **Rational Precision:** Math is performed using Integer Numerators and Denominators.
*   **Algorithmic Code:** High-level functions are lists of descriptive steps. No "god functions". No inline comments explaining *what*; only *why*.
*   **Assertion Heavy:** Fail fast. No fallbacks.

---

## 2. The Data Model (Database)

We will **delete the existing `schema.sql`** and write a new one.

### 2.1 Table: `sequences`
| Column | Type | Constraints | Meaning |
| :--- | :--- | :--- | :--- |
| `fps_numerator` | INTEGER | NOT NULL, > 0 | Sequence Video Rate (e.g. 24). |
| `fps_denominator` | INTEGER | NOT NULL, > 0 | Sequence Video Rate (e.g. 1). |
| `audio_rate` | INTEGER | NOT NULL, > 0 | Project/Sequence Audio Rate (e.g. 48000). |
| `view_start_frame` | INTEGER | NOT NULL | Viewport Start (Video Frames). |
| `view_duration_frames` | INTEGER | NOT NULL | Viewport Zoom (Video Frames). |
| `playhead_frame` | INTEGER | NOT NULL | Playhead Position (Video Frames). |

### 2.2 Table: `tracks`
| Column | Type | Constraints | Meaning |
| :--- | :--- | :--- | :--- |
| `id` | TEXT | PRIMARY KEY | UUID. |
| `sequence_id` | TEXT | FOREIGN KEY | Parent Sequence. |
| `track_type` | TEXT | 'VIDEO'/'AUDIO' | Determines the timebase. |
| `track_index` | INTEGER | NOT NULL | Visual order. |

*   **Video Tracks:** Always operate at Sequence `fps`.
*   **Audio Tracks:** Always operate at Sequence `audio_rate`.

### 2.3 Table: `clips`
Each clip is self-describing. It stores its position and length in its *own* timebase (which matches the track it is on).

| Column | Type | Constraints | Meaning |
| :--- | :--- | :--- | :--- |
| `timeline_start_frame` | INTEGER | NOT NULL | Position on timeline (in Clip's Rate). |
| `duration_frames` | INTEGER | NOT NULL, > 0 | Length (in Clip's Rate). |
| `source_in_frame` | INTEGER | NOT NULL | Trim In (in Clip's Rate). |
| `source_out_frame` | INTEGER | NOT NULL | Trim Out (in Clip's Rate). |
| `fps_numerator` | INTEGER | NOT NULL, > 0 | Definition of "1 Frame" (e.g. 24 or 48000). |
| `fps_denominator` | INTEGER | NOT NULL, > 0 | Definition of "1 Frame" (e.g. 1 or 1). |

---

## 3. The Lua Object Model (`RationalTime`)

*   `src/lua/core/rational.lua` (Implemented).
*   **Strict Validation:** Constructor crashes (`error`) on non-integer inputs.

---

## 4. Implementation Phases

### Phase 1: Foundation (Schema & Library) [COMPLETE]
1.  **Replace Schema:** Delete `src/core/persistence/schema.sql`. Create new schema using the columns above. (Done)
2.  **Rational Library:** (Done).

### Phase 2: Domain Model Hard-Switch [COMPLETE]
1.  **Update Models:** `clip.lua`, `sequence.lua`, `media.lua`, `track.lua`.
    *   Reads `*_frame` columns directly.
    *   Stores `RationalTime` objects.
    *   **No Adapters:** Logic that tries to use old names (`start_value`) will crash. (Done)

### Phase 2.5: Codebase De-Cluttering (Refactor) [COMPLETE]
1.  **Explode `command_implementations.lua`:** Split into `src/lua/commands/*.lua` (e.g. `insert.lua`, `split.lua`).
    *   Files created, but contain legacy logic that currently crashes.

### Phase 3: Logic Refactoring (The Grind) [IN PROGRESS - BLOCKED]
1.  **Iterative Repair (Current Priority):**
    *   **Fix Critical Commands:** `CreateClip` and `InsertClipToTimeline` are broken (using legacy API).
    *   **Refactor:** Update commands to fetch Sequence FPS, construct `Rational` objects, and pass them to `Clip.create`.
    *   **Test:** Verify with `test_frame_accuracy.lua` (to be created/updated).
2.  **Audio Logic:**
    *   Implement Snap vs Sample logic using `Rational` math helpers.

### Phase 4: UI & C++ Renaming
1.  **Rename:** `ScriptableTimeline` -> `TimelineRenderer`.
2.  **Update:** Lua View Layer converts `Rational` -> Pixels for the renderer.

---

## 5. Verification Strategy
1.  **Unit Tests:** `test_rational.lua` (Math correctness).
2.  **Integration Test:** `test_frame_accuracy.lua`.
3.  **Legacy Coverage:** Port the *logic* of `test_ripple_operations.lua` to a new Integration Test that uses real commands against the new schema.
