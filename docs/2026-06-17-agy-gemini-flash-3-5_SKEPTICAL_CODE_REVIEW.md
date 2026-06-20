# Skeptical Code Review — 2026-06-17
_Branch: per-channel-audio — reviewing recent feature commits and active workspace changes_

## Executive Summary
- **Two active test failures are present in the test suite**: One is a stale assertion in `test_media_tc_extraction.lua` (expects `ensure_master` to assert on nameless TC video media, but behavior was changed to default to `00:00:00:00`). The other is an invariant violation in `test_relink_clips_undo.lua` which inserts empty JSON settings (`'{}'`), causing a crash on `Project.get_master_clock_hz_for_id` during clip rebinding.
- **Malloc in hot loop**: `DecodeAudioRange` in `emp_reader.cpp` allocates a `std::vector<float> discard` inside its frame decode loop while skipping pre-roll frames during seek operations, violating the constraint **"NEVER MALLOC IN HOT LOOPS"**.
- **Model property mapping inconsistency**: `clip.lua` maps database column `playhead_frame` to Lua property `playhead_frame`, retaining the `_frame` suffix contrary to the rule **"LUA CLIP FIELD NAMES DROP `_frame`/`_frames` SUFFIX"**, while sequence properties map it cleanly to `playhead_position`.
- **DRY and MVC architectures are clean**: View-pull patterns and signal-based invalidation conform perfectly to MVC boundaries. Track naming and lazy iXML metadata probing are encapsulated in single-responsibility modules without duplication.
- **Monolithic function size**: The C++ function `DecodeAudioRange` has grown to ~220 lines and handles several distinct concerns.

---

## High Severity

### Active Test Failure: Stale Assertion in `test_media_tc_extraction.lua`
*   **File:** [test_media_tc_extraction.lua:L172-174](file:///Users/joe/Local/jve-spec-kit-claude/tests/synthetic/lua/test_media_tc_extraction.lua#L172-174)
*   **Evidence:** The test expects `Sequence.ensure_master` to throw an error for nameless TC video media:
    ```lua
    expect_error("video media without TC → ensure_master asserts", function()
        Sequence.ensure_master("m_video_no_tc", "proj1")
    end, "no video TC origin")
    ```
    However, on 2026-06-14, the crash fix for no-TC timelines was implemented, making `ensure_master` default to origin `00:00:00:00` for no-TC media (removing the assert).
*   **Impact:** The test fails because `ensure_master` succeeds instead of throwing an error.
*   **Remediation:** Update the test expectation to assert that a master clip is successfully created with `source_in = 0` (corresponds to `00:00:00:00` frame 0), verifying the new fallback behavior.

### Active Test Failure: DB Settings Invariant Violation in `test_relink_clips_undo.lua`
*   **File:** [test_relink_clips_undo.lua:L44](file:///Users/joe/Local/jve-spec-kit-claude/tests/synthetic/lua/test_relink_clips_undo.lua#L44)
*   **Evidence:** The SQL seeding inserts projects settings as `'{}'`:
    ```sql
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'Relink Project', 'resample', %d, %d, '{}');
    ```
    During clip rebinding, `Project.get_master_clock_hz_for_id` is called, which executes:
    ```lua
    local v = stmt:value(0); stmt:finalize()
    assert(type(v) == "number" and v > 0, string.format(...))
    ```
*   **Impact:** Since the JSON has no `master_clock_hz` key, `v` is `nil`, triggering a crash. This violates Rule 2.13 (no silent fallbacks/defaults for required settings) and causes test failures.
*   **Remediation:** Update the raw SQL seed in `test_relink_clips_undo.lua` to include `"master_clock_hz"` (e.g., `705600000`) in the settings JSON.

### Malloc in Hot Loop: `emp_reader.cpp` Pre-roll Prime Allocation
*   **File:** [emp_reader.cpp:L1135](file:///Users/joe/Local/jve-spec-kit-claude/src/editor_media_platform/src/emp_reader.cpp#L1135)
*   **Evidence:** Inside `DecodeAudioRange`, when skipping frames before the target range to prime the resampler filter, a new vector is allocated inside the loop for every skipped frame:
    ```cpp
    if (frame_end_us <= t0_us) {
        if (need_seek) {
            int64_t prime_out = m_impl->resample_ctx.get_out_samples(frame_samples);
            if (prime_out > 0) {
                std::vector<float> discard(prime_out * RESAMPLER_OUTPUT_CHANNELS); // Heap allocation in loop
                m_impl->resample_ctx.convert(
                    m_impl->m_audio_frame->data, frame_samples,
                    discard.data(), prime_out);
            }
        }
    ```
*   **Impact:** This violates the core constraint **"NEVER MALLOC IN HOT LOOPS"** (heap allocation in frame decode loop during seeking/playback).
*   **Remediation:** Declare a reusable pre-allocated scratch buffer inside the `m_impl` object or as a function-local scratch vector defined outside the loop scope, and resize it only if it grows.

---

## Medium Severity

### Suffix Drop Rule Inconsistency in `clip.lua`
*   **File:** [clip.lua:L125-126](file:///Users/joe/Local/jve-spec-kit-claude/src/lua/models/clip.lua#L125-126)
*   **Evidence:** The column `playhead_frame` is mapped directly to a clip property called `playhead_frame`:
    ```lua
    playhead_frame = assert(query:value(17), string.format(
        "Clip.load: playhead_frame is NULL for clip %s", tostring(clip_id))),
    ```
*   **Impact:** This violates the rule **"LUA CLIP FIELD NAMES DROP `_frame`/`_frames` SUFFIX"**, which states SQL column suffixes should be dropped in the model (e.g. `sequence_start_frame` -> `sequence_start`, `duration_frames` -> `duration`). Furthermore, the sequence model maps this cleanly to `playhead_position`, making the clip-level property inconsistent.
*   **Remediation:** Rename the loaded Lua property to `playhead_position` (matching `Sequence`) or `playhead`, and update any referencing code.

### Monolithic C++ Function Size: `DecodeAudioRange`
*   **File:** [emp_reader.cpp:L1000-1228](file:///Users/joe/Local/jve-spec-kit-claude/src/editor_media_platform/src/emp_reader.cpp#L1000-1228)
*   **Evidence:** `DecodeAudioRange` is approximately 220 lines long and handles many coupled responsibilities: resampler reinitialization, duration calculation, seek verification, pre-roll frame decoding/filter priming, packet decode iteration, and audio data copying into target buffers.
*   **Impact:** Violates Rule 2.5 (functions should read like high-level algorithms) and Rule 2.6 (functions should be short and focused).
*   **Remediation:** Extract seek pre-roll frame skipping and the packet decoding loop into dedicated private helper methods in `Reader`.

---

## Style, DRY, and MVC Compliance

### 1. DRY Compliance (Rule 2.16)
*   **Track Name Mutations:** Track renaming is cleanly isolated. Precedence resolving (`arg_track_id` -> `focused_track_id` -> clip track) is encapsulated in `rename_track.lua`, whereas command execution and database persistence are inside `set_track_name.lua` and `track.lua`. No redundant SQL queries are introduced.
*   **Metadata Probing:** Chunk walking and iXML parsing logic are contained entirely within `channel_names.lua`.

### 2. MVC Architecture (Rule 3.0)
*   **View-Pull Pattern:** Views pull layout values dynamically from the model. `timeline_panel.lua` pulls labels via `database.get_track_channel_source()` and lazy probes via `channel_names.get()`.
*   **Signal Propagation:** The views listen to model updates via the `track_name_changed` broadcast signal and invoke redrawing/re-pulling operations cleanly. There are no direct imperatively pushed labels to the view.

### 3. Coding Style & Invariants (Rule 3.14 / 2.13)
*   No instances of marketing speak or superlatives were found.
*   Assertions are present for all invalid/empty parameters.
*   Intentional defaults (e.g., `volume = 1.0`) are annotated with `-- NSF-OK`.
