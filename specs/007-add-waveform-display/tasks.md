# Tasks: Waveform Display on Timeline Audio Clips

**Input**: Design documents from `/specs/007-add-waveform-display/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/, quickstart.md

## Phase 3.1: Setup

- [x] T001 Create `<project>.jvp-cache/peaks/` directory infrastructure. In `src/lua/core/database.lua` (or wherever project path is resolved), add a function `get_peak_cache_dir(project_path)` that returns `<project>.jvp-cache/peaks/` and ensures the directory exists. No fallbacks — assert if project_path is nil.

- [x] T002 Add peak file constants module at `src/lua/core/media/peak_constants.lua`. Define: `PEAK_MAGIC = "JVPK"`, `PEAK_VERSION = 1`, `BASE_SAMPLES_PER_PEAK = 256`, `MIPMAP_LEVELS = 4`, `HEADER_SIZE = 64`, `SAMPLES_PER_LEVEL = {256, 512, 1024, 2048}`. These are used by both Lua tests and Lua-side logic. C++ will have its own constants in the header file.

## Phase 3.2: Tests First (TDD) — MUST COMPLETE BEFORE 3.3

**CRITICAL: These tests MUST be written and MUST FAIL before ANY implementation**

- [x] T003 [P] Lua test for peak file math at `tests/test_peak_math.lua`. Test mipmap bin count calculation: given total_samples and base_spp=256, verify bin counts at each level. Test level selection: given samples_per_pixel, verify correct mipmap level chosen (coarsest where spp/pixel <= 1.0). Test edge cases: 0 samples, 1 sample, exactly 256 samples, prime number of samples. Use `require("test_env")`, compute expected values manually with non-trivial inputs (e.g., total_samples=1234567, not round numbers).

- [x] T004 [P] Lua test for waveform color derivation at `tests/test_waveform_color.lua`. Test that `derive_waveform_color("#32986b")` returns a color 40% darker (RGB * 0.6). Test with clip_audio color, clip_audio_disabled color, and boundary values (#000000, #ffffff). Parse hex → RGB → darken → hex. Use `require("test_env")`.

- [x] T005 [P] Lua test for peak coordinate mapping at `tests/test_peak_coords.lua`. Given source_in, source_out (in source samples), clip pixel width, and base_spp: verify correct source sample range → peak bin range mapping. Test with non-trivial source_in (e.g., 188160, not 0). Test that trim/slip changes offset but not peak data lookup logic. Test speed != 1.0 stretches the mapping.

- [x] T006 [P] Lua test for peak cache lifecycle at `tests/test_peak_cache.lua`. Test: `ensure_peaks` with missing file triggers generation request. Test: `get_status` returns "none" / "generating" / "complete". Test: `invalidate` removes entry. Test: `cleanup_orphans` with a set of active IDs retains matching, removes non-matching. Use /tmp/jve/ test directory with real filesystem operations. Use `require("test_env")`.

- [ ] T007 [P] C++ integration test for peak file binary format. Create test script at `tests/test_peak_file_integration.lua` that runs via `--test` mode. Generate a known audio signal (or use a short test WAV), request peak generation, wait for completion, then read back the `.peaks` file and verify: magic="JVPK", version=1, correct bin counts, min/max values within expected range for known signal content.

## Phase 3.3: Core Implementation — C++ Layer (ONLY after tests are failing)

- [x] T008 Create `src/editor_media_platform/include/editor_media_platform/emp_peak_file.h` and `src/editor_media_platform/src/emp_peak_file.cpp`. Implement: `PeakFileHeader` struct (64 bytes, see data-model.md), `PeakFileWriter` (writes header + peak data atomically via .tmp rename), `PeakFileReader` (mmap-based, validates header magic/version, provides `query(source_start_sample, source_end_sample, pixel_width)` returning float* array of min/max pairs at correct mipmap level). See contracts/peak-cache.md for query interface. Add to CMakeLists.txt.

- [x] T009 Create `src/editor_media_platform/include/editor_media_platform/emp_peak_generator.h` and `src/editor_media_platform/src/emp_peak_generator.cpp`. Implement: `PeakGenerator` class with `RequestPeaks(media_id, media_path, output_path)`, `CancelPeaks(media_id)`, `CancelAll()`, `GetStatus(media_id)`. Background thread decodes audio via EMP Reader sequentially, computes min/max per 256-sample bin (sum channels to mono), builds all 4 mipmap levels in one pass, writes via PeakFileWriter. Atomic progress counter. See contracts/peak-generator.md. Add to CMakeLists.txt.

- [x] T010 Add `WAVEFORM` draw command to `src/timeline_renderer.h` and `src/timeline_renderer.cpp`. Add `addWaveform(x, y, width, height, peaks, peak_count, color)` method. New `DrawCommand::WAVEFORM` type with `std::vector<float> peak_data` and `peak_count`. In `executeDrawingCommands()`, implement WAVEFORM case: draw vertical lines from min to max per peak bin, centered vertically in the clip rect. See contracts/waveform-renderer.md for QPainter pseudocode.

- [x] T011 Add Lua bindings for peak operations in `src/lua/qt_bindings/emp_bindings.cpp`. Add bindings: `EMP.PEAK_REQUEST(media_id, media_path, output_path)`, `EMP.PEAK_CANCEL(media_id)`, `EMP.PEAK_CANCEL_ALL()`, `EMP.PEAK_STATUS(media_id) → {state, progress_samples, total_samples}`, `EMP.PEAK_LOAD(file_path) → peak_handle`, `EMP.PEAK_QUERY(peak_handle, start_sample, end_sample, pixel_width) → lightuserdata, count`, `EMP.PEAK_HEADER(peak_handle) → table`, `EMP.PEAK_RELEASE(peak_handle)`. Register all in the EMP table. Depends on T008, T009.

- [x] T012 Add `timeline.add_waveform` Lua binding in `src/timeline_renderer.cpp`. Binding signature: `lua_timeline_add_waveform(L)` takes widget, x, y, width, height, peak_data_ptr (lightuserdata), peak_count (int), color (string). Copies float data from lightuserdata into DrawCommand. Register in `registerTimelineBindings()`. Depends on T010.

## Phase 3.4: Core Implementation — Lua Layer

- [x] T013 Create `src/lua/core/media/peak_cache.lua`. Implement the interface from contracts/peak-cache.md: `init(project_cache_dir)`, `ensure_peaks(media_id, media_path, source_mtime)`, `get_visible_peaks(media_id, source_start, source_end, pixel_width)`, `get_status(media_id)`, `get_progress(media_id)`, `invalidate(media_id)`, `cleanup_orphans(active_media_ids)`, `clear()`. Uses EMP.PEAK_* bindings. Manages in-memory cache of loaded peak handles. `ensure_peaks` checks mtime staleness, triggers EMP.PEAK_REQUEST if needed. `get_visible_peaks` calls EMP.PEAK_QUERY with correct mipmap selection. Depends on T011.

- [x] T014 Create waveform color derivation function. Add `derive_waveform_color(hex_color)` either in `peak_cache.lua` or a small utility. Takes "#rrggbb" hex string, returns "#rrggbb" at 60% brightness (multiply each RGB component by 0.6, clamp to 0-255). Used by timeline_view_renderer for waveform color. No external dependencies — pure function.

## Phase 3.5: UI Integration

- [x] T015 Integrate waveform rendering into `src/lua/ui/timeline/view/timeline_view_renderer.lua`. In `draw_clip_instance()`, after the body rect (line ~670) and before text label (line ~677): if `is_audio` and not `outline_only` and track waveform is enabled, call `peak_cache.get_visible_peaks(clip.media_id, clip.source_in, clip.source_out, draw_width)`. If peaks returned, call `timeline.add_waveform(view.widget, visible_x, y, draw_width, clip_height, peaks, count, wave_color)`. For disabled clips, derive color from disabled body color instead. Require peak_cache at module top. Depends on T012, T013, T014.

- [x] T016 Add waveform toggle state to `src/lua/ui/timeline/state/track_state.lua`. Add `get_track_waveform_enabled(track_id)` and `set_track_waveform_enabled(track_id, enabled)`. Default: true for audio tracks, always false for video. Persist in `sequence_track_layouts.track_heights_json` (extend existing JSON to include `waveform_enabled` per track). Notify listeners on change so timeline repaints.

- [x] T017 Add waveform toggle to track headers in `src/lua/ui/timeline/timeline_panel.lua`. Add a toggle button in the audio track header button row (near Mute/Solo/Record). Button label "W" or waveform icon. On click: call `state.set_track_waveform_enabled(track_id, not current)`. Visual: highlighted when active, dimmed when inactive. Audio tracks only — skip for video tracks. See contracts/track-toggle.md. Depends on T016.

## Phase 3.6: Integration

- [x] T018 Hook peak invalidation into `src/lua/core/media/media_status.lua`. In `_on_file_changed(path)`, after `reprobe_and_notify(path)`, look up the media_id for the changed path and call `peak_cache.invalidate(media_id)`. This triggers peak regeneration via the existing file watcher infrastructure. Also check mtime on project open (in the background codec probe or init_watcher). Depends on T013.

- [x] T019 Trigger peak generation on project open. In the project open flow (likely `open_project.lua` or `post_open_init`), after media is loaded, iterate all audio media files and call `peak_cache.ensure_peaks(media_id, media_path, mtime)` for each. This queues background generation for any media without cached peaks, and validates existing peak files against current mtime. Depends on T013.

- [x] T020 Implement orphan peak cleanup on project close. In the project close flow (or via `project_changed` signal handler), call `peak_cache.cleanup_orphans(active_media_ids)` where `active_media_ids` is the set of media IDs still referenced by the project DB plus any media reachable from the undo stack. Then call `peak_cache.clear()` to release all mmap handles. Identify active undo media IDs by querying command history snapshots. Depends on T013.

## Phase 3.7: Polish & Validation

- [ ] T021 [P] C++ integration test: full pipeline via `--test` mode. Create `tests/test_waveform_pipeline.lua`. Import a test audio file, place on timeline, verify peak generation completes, verify `peak_cache.get_visible_peaks` returns data, verify `timeline.add_waveform` doesn't crash. Run via `./build/bin/JVEEditor --test tests/test_waveform_pipeline.lua`. Save output to /tmp, grep for errors.

- [ ] T022 [P] Performance test at `tests/test_waveform_perf.lua`. Measure timeline repaint time with and without waveforms enabled. Create a timeline with 10 audio clips, render 100 frames, compute average repaint delta. Assert < 2ms additional per PR-002. Run via `--test` mode.

- [x] T023 Run `make -j4` — verify 0 luacheck warnings, all tests pass, clean C++ build.

- [ ] T024 Manual validation: execute all 10 scenarios from `specs/007-add-waveform-display/quickstart.md`. Requires running the app interactively.

- [ ] T025 Monitor waveform strip (lower priority). Add waveform display across the bottom of source and sequence monitors when viewing audio-bearing media. Reuses peak_cache and peak data. Requires understanding the monitor rendering pipeline (sequence_monitor.lua, source_viewer). This is a separate integration point but shares all peak infrastructure from T008-T013.

## Dependencies

```
T001, T002 → foundation for everything
T003-T007 → must complete and FAIL before T008+
T008 → T009 (generator uses file writer)
T008, T009 → T011 (bindings wrap C++ classes)
T010 → T012 (Lua binding wraps addWaveform)
T011, T012 → T013 (peak_cache uses EMP bindings + timeline binding)
T013, T014 → T015 (renderer uses cache + color)
T016 → T017 (UI button calls state module)
T013, T014, T016 → T015 (renderer uses cache + color + toggle state)
T013 → T018, T019, T020 (all depend on peak_cache)
T015+ → T021, T022 (integration/perf tests need working pipeline)
All → T023, T024 (final validation)
T025 → after T013 (shares peak infrastructure, independent of timeline UI)
```

## Parallel Execution Examples

```
# Phase 3.2 — all test files are independent:
T003: "Lua test for peak file math at tests/test_peak_math.lua"
T004: "Lua test for waveform color derivation at tests/test_waveform_color.lua"
T005: "Lua test for peak coordinate mapping at tests/test_peak_coords.lua"
T006: "Lua test for peak cache lifecycle at tests/test_peak_cache.lua"
T007: "C++ integration test for peak file binary format"

# Phase 3.3 — C++ modules (T008 || T010, then T009 after T008):
T008: "Peak file reader/writer in emp_peak_file.h/.cpp"
T010: "WAVEFORM draw command in timeline_renderer.h/.cpp"
# then T009 after T008 completes

# Phase 3.7 — polish tests are independent:
T021: "Full pipeline integration test"
T022: "Performance test for waveform rendering"
```

## Validation Checklist

- [x] All contracts have corresponding tests (peak-generator→T007, peak-cache→T006, waveform-renderer→T005+T021, track-toggle→T024)
- [x] All entities have model/implementation tasks (PeakFile→T008, PeakGenerator→T009, PeakCache→T013)
- [x] All tests come before implementation (T003-T007 before T008+)
- [x] Parallel tasks truly independent (different files, no shared state)
- [x] Each task specifies exact file path
- [x] No task modifies same file as another [P] task

## Notes
- [P] tasks = different files, no dependencies
- Verify tests fail before implementing
- Commit after each task
- C++ changes require `make -j4` to compile; Lua-only changes can be tested with `--test` mode directly
- Peak generation uses EMP Reader — same FFmpeg infrastructure as playback decode
- Monitor waveform (T025) is explicitly lower priority and can be deferred
