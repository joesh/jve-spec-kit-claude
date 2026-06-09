# Quickstart: File Original TC Verification

**Feature**: 009-drp-importer-must

## Prerequisites

- Build: `make -j4` passes (all existing tests green)
- Two-clips fixture DRP: `/Users/joe/Library/Mobile Documents/com~apple~CloudDocs/Downloads/two clips same file different tc.drp`
- Anamnesis production DRP + fixture tree at `tests/fixtures/media/anamnesis/`

## Verification Steps

### 1. Two-clips fixture — DRP import

```bash
# Convert the fixture DRP → temp project
cd tests && luajit test_harness.lua test_drp_dual_tc.lua
```

Expected:
- Both media rows have `start_tc_value` populated
- Override row: `start_tc_value = 1194321` (13:16:12:21 at 25fps), `file_original_timecode = 11383` (00:07:35:08)
- Non-override row: `start_tc_value = 11383` (00:07:35:08), `file_original_timecode` absent (nil)
- Both rows' `file_original_timecode` (or `start_tc_value` for the non-override) = 11383

### 2. Relinker accepts on file_original_timecode

```bash
cd tests && luajit test_harness.lua test_relink_file_original_tc.lua
```

Expected:
- Candidate with probed container TC `00:07:35:08` matches the override row via `file_original_timecode`
- No source_in remap (clip source ranges unchanged)
- Candidate is NOT marked as `tc_mismatch`

### 3. EMP override setter

```bash
# Integration test via --test mode (needs C++ bindings)
./build/bin/JVEEditor --test tests/synthetic/binding/test_emp_tc_override.lua
```

Expected:
- MediaFile opened, setter called with override TC
- `MEDIA_FILE_INFO` reports the overridden `first_frame_tc`
- Assert fires if setter called after decode begins

### 4. Full end-to-end — anamnesis gold master

```bash
# Integration test via --test mode
JVE_LOG=media:detail ./build/bin/JVEEditor --test tests/synthetic/binding/test_e2e_retime_relink.lua > /tmp/e2e_output.txt 2>&1
```

Expected:
- VFX clips that previously failed relink now succeed
- `file_frame >= 0` invariant never fires
- Offline count reduced vs pre-feature baseline

### 5. Backward compatibility — camera footage

```bash
cd tests && luajit test_harness.lua test_drp_retime_curve_walk.lua
```

Expected:
- All existing retime/relink assertions still pass
- No `file_original_timecode` populated (camera footage, no override)

### 6. Full regression

```bash
make -j4
```

Expected: All tests pass, zero luacheck warnings.
