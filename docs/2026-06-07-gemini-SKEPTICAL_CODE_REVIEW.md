# SKEPTICAL CODE REVIEW
**Date:** 2026-06-07
**Reviewer:** Gemini
**Target:** Uncommitted Changes in Workspace (`/tmp/dirty_diff.txt`)

This review evaluates the current uncommitted changes against the strict engineering mandates defined in `ENGINEERING.md`. 

## 1. Fail-Fast Invariants & Silent Fallbacks (Rules 1.14 & 2.13)
*Status: **VIOLATION***

The codebase strictly mandates that we prefer immediate hard failure over recovery and **never** use fallback values like `or 0`, `or nil`, or `or {}`. The diff introduces multiple silent fallbacks:

- **`src/lua/ui/timeline/timeline_panel.lua`**:
  - `state.get_playhead_position() or 0`: Introduces a silent default value for the playhead position. If the playhead position is nil, it should assert, not default to 0.
  - `if not rate then return "" end` inside `get_formatted_playhead_timecode`: This is a graceful degradation/silent fallback. If `rate` is missing, the application should crash to force a fix of the underlying invariant.
  - The use of `print()` for debugging invariant violations:
    ```lua
    if not (rate.fps_numerator and rate.fps_denominator) then
        local dkjson = require("dkjson")
        print("DEBUG: missing sequence fps metadata! rate=" .. dkjson.encode(rate))
    end
    ```
    *Rule 1.14 states: "A 'print and continue' is not acceptable for invariants. Use logger module for info and debug prints."* This should be an immediate `assert()` with the JSON payload included in the crash message.

- **`tests/test_relink_zero_padding_boundary.lua`**:
  - Uses `type(text_or_attrs) == "table" and text_or_attrs or {}` and `text_or_attrs or ""`. This is a classic `or default` pattern that masks missing parameters.

- **`tests/test_trim_head_tail.lua`**:
  - `source_in = source_in or 100`: This test helper defaults `source_in` instead of requiring the caller to be explicit. Fallbacks in tests are particularly dangerous as they can mask regressions.

## 2. Structural Debt & Model API Inconsistencies (SQL Isolation)
*Status: **STRUCTURAL DEBT***

While the migration of raw SQL `INSERT` statements in the tests to Model API calls (`Project.create`, `Sequence.create`, `Track.create`, `Clip.create`) is a massive improvement for SQL Isolation, it exposes a severe inconsistency in the Model API design:

- **ActiveRecord vs. Direct Insert**:
  In `tests/test_relink_clips_integration.lua` and `tests/test_trim_head_tail.lua`, we see:
  ```lua
  Project.create(...):save()
  Track.create_video(...):save()
  ```
  But for clips:
  ```lua
  Clip.create({ ... }) -- No :save() called!
  ```
  `Clip.create` bypasses the standard `.save()` pattern used by all other models. Inside `src/lua/models/clip.lua`, `Clip._create_v13_row` immediately executes an `INSERT INTO clips` statement rather than returning an unpersisted model instance that requires `.save()`. This is an API divergence that breaks DRY principles and will inevitably lead to developer confusion, missed saves, or accidental immediate persistence when transactional boundaries are expected.

## 3. Architectural Correctness (Model-View-Controller)
*Status: **WARNING / SMELL***

- **`core.watchers` injection in models**:
  In `src/lua/models/clip.lua`, the `save_internal` and `delete` methods now explicitly call:
  ```lua
  require("core.watchers").notify_clip(self.id, self.owner_sequence_id)
  ```
  While `core.watchers` appears to be a queue-based pub/sub mechanism (which aligns with MVC pull), hardcoding UI-centric notification dispatchers directly inside model persistence methods smells of tight coupling. The model should emit a generic data-layer signal (e.g., via `core.signals`), and a separate coordinator or the `command_manager` should translate those into UI invalidation events. Hooking `watchers` directly inside `Clip:save_internal` blurs the line between data persistence and UI orchestration.

## 4. Coding Style and Algorithm Readability (Rule 2.5)
*Status: **IMPROVEMENT WITH CAVEATS***

- **`src/lua/core/command_manager.lua`**:
  The extraction of `execute_with_recording_ceremony` from `_execute_body` is a strong step toward Rule 2.5 (Functions Read Like Algorithms). However, the newly extracted `execute_with_recording_ceremony` is still a monolithic >150-line function that handles state hashing, capturing the playhead, history cursor movement, execution, snapshotting, collision retries, and pre-commit mutation validation. It remains an overly complex "God function" that mixes high-level algorithm steps with low-level implementation details (e.g., inline loops for pre-commit mutation rejection). Further decomposition is required to meet the strict "tell the story of WHAT happens" standard.

## 5. The Good: Fail-Fast Improvements
- **`tools/resolve-helper/resolve_handle.py`**:
  The removal of the silent `"unavailable"` fallback in `version_string()` is an excellent application of the Fail-Fast policy. It now explicitly raises a `RuntimeError` if Resolve is unreachable or if it is in a terminal error state, adhering perfectly to Rule 2.13 ("No Fallbacks or Default Values").

## Summary of Next Actions
1. **Remove all `or 0` / `or nil` fallbacks** in `timeline_panel.lua` and replace them with hard assertions.
2. **Remove `print` statements** used for invariant checks and replace them with `assert` or logger module calls.
3. **Unify the Model persistence API**: Refactor `Clip.create()` to return an unpersisted model instance that requires `:save()`, aligning it with `Project`, `Sequence`, and `Track`.
4. **Decompose `execute_with_recording_ceremony`** into discrete, well-named helper functions per Rule 2.5.
