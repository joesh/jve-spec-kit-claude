# Tasks: File Original TC for Override-Aware Relink & Decode

**Input**: Design documents from `/specs/009-drp-importer-must/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/, quickstart.md

## Phase 3.1: Setup

- [x] **T001** Copy two-clips fixture DRP to test fixtures and verify clean build

  Copy `/Users/joe/Library/Mobile Documents/com~apple~CloudDocs/Downloads/two clips same file different tc.drp` to `tests/fixtures/resolve/two_clips_same_file_different_tc.drp`. Run `make -j4` and confirm all existing tests pass (baseline).

## Phase 3.2: Tests First (TDD) — MUST COMPLETE BEFORE 3.3

**CRITICAL: These tests MUST be written and MUST FAIL before ANY implementation.**

- [x] **T002** [P] Write `tests/test_drp_dual_tc.lua` — DRP import file_original_timecode assertion

  Pure Lua test. Import the two-clips fixture DRP (`tests/fixtures/resolve/two_clips_same_file_different_tc.drp`) via `drp_importer.convert()`. Open the resulting `.jvp`, query both media rows. Assert:
  - Both rows exist (same underlying file, two master clips)
  - Override row: `start_tc_value = 1194321` (13:16:12:21 at 25fps), `file_original_timecode = 11383` (00:07:35:08 at 25fps)
  - Non-override row: `start_tc_value = 11383` (00:07:35:08), `file_original_timecode` is nil
  - Both rows agree on `file_original_timecode` value (or start_tc_value for non-override): `11383`

  **Expected at this point**: FAILS — `file_original_timecode` not populated by current importer.

  **File**: `tests/test_drp_dual_tc.lua`
  **Reads**: `src/lua/importers/drp_importer.lua`, `src/lua/models/media.lua`

- [x] **T003** [P] Write `tests/test_relink_file_original_tc.lua` — relinker accepts on file_original_tc

  Pure Lua test. Construct a `media_info` table with:
  - `media_start_tc_value = 1194321` (override TC 13:16:12:21)
  - `media_start_tc_rate = 25`
  - `media_file_original_tc = 11383` (file container TC 00:07:35:08)
  
  Construct a mock `probe_fn` that returns `start_tc_value = 11383` (candidate's container matches file_original_tc, not the override). Call `media_relinker.find_candidates_for_media()` with `match_timecode = true`. Assert:
  - Candidate accepted (results array not empty)
  - `tc_mismatch` is false (accepted as clean match, not containment-fallback)
  
  Also test the negative case: candidate with TC matching neither field → rejected (or containment-fallback if `accept_trimmed_media`).

  **Expected at this point**: FAILS — relinker only compares against `media_start_tc_value`.

  **File**: `tests/test_relink_file_original_tc.lua`
  **Reads**: `src/lua/core/media_relinker.lua`

- [x] **T004** Write `tests/binding/test_emp_tc_override.lua` — EMP setter integration test

  Integration test via `--test` mode. Tests:
  1. Open a media file via `EMP.MEDIA_FILE_OPEN(path)`, read `EMP.MEDIA_FILE_INFO(mf)` → note probed `first_frame_tc`.
  2. Call `EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE(mf, override_video_tc, override_audio_tc)`.
  3. Read `EMP.MEDIA_FILE_INFO(mf)` again → assert `first_frame_tc == override_video_tc`.
  4. (Separate sub-test) Open another file, start a decode, THEN call setter → assert fires (test catches the error).

  Use a real fixture file from `tests/fixtures/media/` that has a known container TC.

  **Expected at this point**: ERRORS — `MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE` binding doesn't exist yet.

  **File**: `tests/binding/test_emp_tc_override.lua`
  **Reads**: `src/lua/qt_bindings/emp_bindings.cpp`, `src/editor_media_platform/include/editor_media_platform/emp_media_file.h`

## Phase 3.3: Core Implementation (ONLY after tests are failing)

### Layer 1: DRP Import (Lua)

- [x] **T005** Extend `decode_bt_audio_duration` to return `start_time_seconds`

  In `src/lua/importers/drp_importer.lua` at ~line 581, the function already calls `decode_tlv_fields()` which parses all TLV fields including `StartTime`. Currently only `Duration` and `SampleRate` are extracted. Add `StartTime` to the return table:

  ```lua
  local start_time = fields["StartTime"]  -- BE double, seconds since midnight
  return {
      duration_samples = duration,
      sample_rate = sample_rate,
      start_time_seconds = start_time,  -- NEW: file container TC origin
  }
  ```

  `start_time_seconds` is nil when the `StartTime` field is absent from the TLV. The function still returns successfully with `duration_samples` and `sample_rate` (existing callers unaffected). The caller (T006) checks for nil and handles per FR-003.

  **File**: `src/lua/importers/drp_importer.lua` (~line 581–601)

- [x] **T005a** Change DRP importer media dedup key to `(file_path, media_start_time)`

  In `src/lua/importers/drp_importer.lua` at ~line 2970, the dedup check uses `media_by_path[media_item.file_path]`. Two master clips pointing at the same file but with different `media_start_time` values (one with Set Timecode override, one without) are silently merged into one row.

  Change the dedup key to include the displayed TC:
  ```lua
  local dedup_key = media_item.file_path .. "|" .. tostring(media_item.media_start_time or "")
  local existing = media_by_dedup_key[dedup_key]
  ```

  Same file + same TC = one row (camera footage, unchanged). Same file + different TC = two rows (override case, per FR-003a).

  Also update `media_by_uuid` mapping to use the correct row for each master clip's UUID.

  **Verify**: T002 (two-clips fixture) depends on this producing two rows.

  **File**: `src/lua/importers/drp_importer.lua` (~line 2965–2975)
  **Depends on**: T005 (same file, sequential)

- [x] **T006** Store `file_original_timecode` in media metadata during DRP import

  In `src/lua/importers/drp_importer.lua`, in the media creation loop (~line 2977–2990 where `media_metadata` is built from `media_start_time`):

  1. For each media item, call `decode_bt_audio_duration()` on the TracksBA hex blob. The function already exists and is called elsewhere for duration — find the call or add one using the master clip's BtAudioInfo hex data.
  2. Extract `start_time_seconds` from the result.
  3. Convert to video frames: `file_tc_video = math.floor(start_time_seconds * native_rate + 0.5)`.
  4. Convert to audio samples: `file_tc_audio = math.floor(start_time_seconds * audio_sr + 0.5)`.
  5. If `file_tc_video ~= start_tc_value` (override exists), add to metadata JSON:
     - `file_original_timecode = file_tc_video`
     - `file_original_timecode_audio = file_tc_audio`
  6. If TracksBA is missing or decode returns nil: `log.error(...)` naming the master clip, skip media row, continue import (FR-003).

  **File**: `src/lua/importers/drp_importer.lua` (~line 2977–2990)
  **Depends on**: T005

- [x] **T007** Add `Media:get_file_original_timecode()` accessor

  In `src/lua/models/media.lua`, add:
  ```lua
  function M:get_file_original_timecode()
      local meta = self:_parsed_metadata()
      if meta and meta.file_original_timecode ~= nil then
          return meta.file_original_timecode, meta.start_tc_rate
      end
      return nil, nil
  end

  function M:get_file_original_timecode_audio()
      local meta = self:_parsed_metadata()
      if meta and meta.file_original_timecode_audio ~= nil then
          return meta.file_original_timecode_audio, meta.start_tc_audio_rate
      end
      return nil, nil
  end
  ```

  **Verify**: Run T002 (`test_drp_dual_tc.lua`). It should now PASS.

  **File**: `src/lua/models/media.lua`
  **Depends on**: T006

### Layer 2: Relinker (Lua)

- [x] **T008** Relinker second-chance TC match on `file_original_timecode`

  In `src/lua/core/media_relinker.lua` at ~line 577–606, inside the TC matching block of `find_candidates_for_media()`:

  Current logic: compute offset between `stored_value` (`media_start_tc_value`) and `cand_tc_value`. If `abs(offset) > 1`, reject or mark `tc_mismatch`.

  New logic: if `abs(offset) > 1` AND `media_info.media_file_original_tc` is not nil, compute a second offset between `media_info.media_file_original_tc` and `cand_tc_value` (at `media_info.media_start_tc_rate`). If `abs(second_offset) <= 1`, accept as a CLEAN match (`tc_mismatch = false`). Only fall through to existing trimmed-media logic if BOTH comparisons fail.

  Also update the `media_info` table construction in `relink_media_batch()` to include `media_file_original_tc` from the media row (via `Media:get_file_original_timecode()` or from the `media_infos` input table).

  **Verify**: Run T003 (`test_relink_file_original_tc.lua`). It should now PASS.

  **File**: `src/lua/core/media_relinker.lua` (~line 577–606), also wherever `media_infos` is built for `relink_media_batch`
  **Depends on**: T007

### Layer 3: EMP C++ — setter + TMB

- [x] **T009** `MediaFile::set_tc_origin_override` implementation

  **Header** (`src/editor_media_platform/include/editor_media_platform/emp_media_file.h`):
  - Add `void set_tc_origin_override(int64_t first_frame_tc, int64_t first_sample_tc);` to `MediaFile` public interface.
  - Add `bool m_decode_started = false;` to `MediaFile` private members.
  - Add `void mark_decode_started();` to `MediaFile` public interface (called by Reader on first decode).

  **Implementation** (`src/editor_media_platform/src/emp_media_file.cpp`):
  ```cpp
  void MediaFile::set_tc_origin_override(int64_t first_frame_tc, int64_t first_sample_tc) {
      JVE_ASSERT(!m_decode_started,
          "MediaFile::set_tc_origin_override: called after decode started on " + m_info.path);
      JVE_ASSERT(first_frame_tc >= 0,
          "MediaFile::set_tc_origin_override: first_frame_tc must be >= 0");
      JVE_ASSERT(first_sample_tc >= 0,
          "MediaFile::set_tc_origin_override: first_sample_tc must be >= 0");
      m_info.first_frame_tc = first_frame_tc;
      m_info.first_sample_tc = first_sample_tc;
  }

  void MediaFile::mark_decode_started() {
      m_decode_started = true;
  }
  ```

  Also: find where `Reader::DecodeAt` / `Reader::DecodeAudio` is first called and add `media_file->mark_decode_started()` there. Check `emp_reader.cpp` or similar for the decode entry points.

  **Files**: `emp_media_file.h`, `emp_media_file.cpp`, and the Reader decode entry point
  **No dependencies on other tasks** (can parallel with T005–T008 Lua work)

- [x] **T010** TMB `SetTcOverrides` + override application in `acquire_reader`

  **Header** (`src/editor_media_platform/include/editor_media_platform/emp_timeline_media_buffer.h`):
  ```cpp
  struct TcOverride {
      int64_t first_frame_tc;
      int64_t first_sample_tc;
  };
  ```
  Add to `TimelineMediaBuffer` class:
  - `void SetTcOverrides(std::unordered_map<std::string, TcOverride> overrides);`
  - Private member: `std::unordered_map<std::string, TcOverride> m_tc_overrides;`

  **Implementation** (`src/editor_media_platform/src/emp_timeline_media_buffer.cpp`):
  - `SetTcOverrides`: store map. Log override count.
  - In `acquire_reader()` at ~line 1914 (after `auto mf = mf_result.value();`, before `auto reader_result = Reader::Create(mf);`):
    ```cpp
    auto tc_it = m_tc_overrides.find(path);
    if (tc_it != m_tc_overrides.end()) {
        mf->set_tc_origin_override(tc_it->second.first_frame_tc,
                                    tc_it->second.first_sample_tc);
    }
    ```

  **Files**: `emp_timeline_media_buffer.h`, `emp_timeline_media_buffer.cpp`
  **Depends on**: T009 (calls set_tc_origin_override)

- [x] **T011** Lua bindings for `TMB_SET_TC_OVERRIDES` and `MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE`

  In `src/lua/qt_bindings/emp_bindings.cpp`:

  1. **MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE(media_file, video_tc, audio_tc)**:
     - Get MediaFile from handle map
     - Call `media_file->set_tc_origin_override(video_tc, audio_tc)`
     - Register at ~line 2087 alongside other MEDIA_FILE_* bindings

  2. **TMB_SET_TC_OVERRIDES(tmb, overrides_table)**:
     - Parse Lua table: `{[path_string] = {video=int, audio=int}, ...}`
     - Build `std::unordered_map<std::string, TcOverride>` and call `tmb->SetTcOverrides(...)`
     - Register alongside other TMB_SET_* bindings (~line 2100+)

  **Verify**: Run T004 (`test_emp_tc_override.lua`) via `--test` mode. It should now PASS.

  **File**: `src/lua/qt_bindings/emp_bindings.cpp`
  **Depends on**: T009, T010

### Layer 4: Playback Integration (Lua)

- [x] **T012** Playback engine builds and sends TMB TC override map

  In `src/lua/core/playback/playback_engine.lua`, find where `TMB_SET_TRACK_CLIPS` is called (around where `_build_tmb_clip` results are sent to TMB). After the clip setup, before the first `TMB_SET_PLAYHEAD`:

  1. Iterate over all media rows referenced by the current sequence's clips.
  2. For each media row with `get_file_original_timecode() ~= nil`:
     - Get `start_tc_value, start_tc_rate` from `media:get_start_tc()`
     - Get `start_tc_audio` from `media:get_audio_start_tc()`
     - Add to overrides table: `overrides[media_path] = { video = start_tc_value, audio = start_tc_audio }`
  3. Call `EMP.TMB_SET_TC_OVERRIDES(tmb, overrides)`.
  4. If overrides table is empty, skip the call (camera-footage-only sequences — no behavioral change).

  **File**: `src/lua/core/playback/playback_engine.lua`
  **Depends on**: T007 (Media accessor), T011 (Lua binding)

## Phase 3.4: Integration & Verification

- [x] **T013** E2E test: extend `tests/binding/test_e2e_retime_relink.lua` for VFX clip override

  Add to the existing e2e test (or create a new section):
  1. After relink, find a VFX clip in the gold master whose media row has `file_original_timecode` populated.
  2. Assert the clip is now online (file_path under fixture tree).
  3. Assert `file_original_timecode ~= start_tc_value` (confirming override was detected).
  4. If running via `--test` mode with full EMP: open the file via `EMP.MEDIA_FILE_OPEN`, verify probed `first_frame_tc` differs from `start_tc_value`, call `EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE(mf, start_tc_value, ...)`, verify `first_frame_tc` now equals `start_tc_value`.
  5. Report: remaining offline count, VFX clips now online count.

  **File**: `tests/binding/test_e2e_retime_relink.lua`
  **Depends on**: T005–T012 (all layers)

- [x] **T014** Verify all TDD tests pass

  Run each test and confirm green:
  ```bash
  cd tests && luajit test_harness.lua test_drp_dual_tc.lua
  cd tests && luajit test_harness.lua test_relink_file_original_tc.lua
  ./build/bin/JVEEditor --test tests/binding/test_emp_tc_override.lua
  JVE_LOG=media:detail ./build/bin/JVEEditor --test tests/binding/test_e2e_retime_relink.lua > /tmp/e2e_output.txt 2>&1
  ```

  All must pass. If any fail, fix the implementation (not the test).

  **Depends on**: T013

## Phase 3.5: Polish

- [x] **T015** [P] Update `docs/resolve-trimmed-handoff-issues.md` per FR-014

  Add a section documenting:
  - The file_original_timecode feature and when it applies (Set Timecode overrides)
  - That projects imported before this fix must be re-imported to populate the new field
  - The three-fix chain: retime curve-walking (8475976) → dedupe salvage (b48b446) → file_original_timecode (this feature)

  **File**: `docs/resolve-trimmed-handoff-issues.md`

- [x] **T016** Full regression — `make -j4`

  Run the complete build + test suite. All tests must pass. Zero luacheck warnings.

  **Depends on**: All tasks

## Dependencies

```
T001 → T002, T003, T004 (setup before tests)
T002, T003 → [parallel, no deps between them]
T004 → [can write alongside T002/T003 but verification needs T011]

T005 → T005a → T006 (same file, sequential)
T006 → T007 (media model reads what importer writes)
T007 → T008 (relinker uses media accessor)
T007 → T002 passes (DRP test green)
T008 → T003 passes (relinker test green)

T009 → T010 (TMB calls setter)
T010 → T011 (bindings wrap TMB method)
T011 → T004 passes (EMP test green)
T011 → T012 (playback calls binding)

T008 + T012 → T013 (E2E needs all layers)
T013 → T014 (verification)
T014 → T015, T016 (polish after green)
```

## Parallel Execution Examples

```
# Wave 1: Setup
Task: T001 "Copy fixture DRP + verify build"

# Wave 2: TDD tests (all parallel — different files)
Task: T002 "Write test_drp_dual_tc.lua"
Task: T003 "Write test_relink_file_original_tc.lua"
Task: T004 "Write test_emp_tc_override.lua"

# Wave 3: Lua implementation + C++ implementation (parallel tracks)
# Track A (Lua — sequential):
Task: T005 → T005a → T006 → T007 → T008
# Track B (C++ — sequential):
Task: T009 → T010 → T011

# Wave 4: Integration (after both tracks complete)
Task: T012 "Playback engine TMB override map"

# Wave 5: E2E + verification
Task: T013 → T014

# Wave 6: Polish (parallel)
Task: T015 "Update docs"
Task: T016 "Full regression"
```

## Validation Checklist

- [x] All contracts have corresponding tests (emp-tc-override → T004, drp-import-file-tc → T002)
- [x] All entities have model tasks (Media accessor → T007)
- [x] All tests come before implementation (T002–T004 before T005–T012)
- [x] Parallel tasks truly independent (T002/T003/T004 are different files; T015/T016 are different files)
- [x] Each task specifies exact file path
- [x] No task modifies same file as another [P] task
- [x] E2E test covers production acceptance (T013 — anamnesis gold master)
- [x] Camera footage correctness covered by existing regression tests (T016 — make -j4)
