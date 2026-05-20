#!/usr/bin/env luajit
--- 019 T003: core/edit_mode module + ToggleTrimMode command contract.
---
--- The source viewer's narrow trim-mode toggle (FR-008..012). Module-level
--- session state with two enum values ("overwrite" | "ripple"), default
--- "overwrite" on every process start. Mutated via set_trim_mode (asserts
--- on enum). Toggled via the ToggleTrimMode command (no default keybind).
---
--- Pinned behaviors:
---   * Initial value is "overwrite" without any prior writes.
---   * set_trim_mode asserts on invalid enum values (FR-009 — no fallback,
---     no silent coerce).
---   * Each set emits trim_mode_changed with (new, old) payload.
---   * _reset_for_tests() restores "overwrite" (validates session-transient
---     semantics — FR-010).
---   * ToggleTrimMode command flips the value.
---
--- Black-box: asserts only on the module's documented API surface.

require("test_env")

local edit_mode = require("core.edit_mode")
local Signals   = require("core.signals")

print("=== test_edit_mode_toggle.lua ===")

-- =============================================================================
-- 1. Initial value (FR-010): "overwrite" on first read.
-- =============================================================================
edit_mode._reset_for_tests()
assert(edit_mode.get_trim_mode() == "overwrite", string.format(
    "edit_mode.get_trim_mode() initial value must be 'overwrite'; got %q",
    tostring(edit_mode.get_trim_mode())))
print("  ✓ initial value is 'overwrite'")

-- =============================================================================
-- 2. set_trim_mode happy paths flip the state (FR-008).
-- =============================================================================
edit_mode.set_trim_mode("ripple")
assert(edit_mode.get_trim_mode() == "ripple",
    "after set_trim_mode('ripple'), get must return 'ripple'")

edit_mode.set_trim_mode("overwrite")
assert(edit_mode.get_trim_mode() == "overwrite",
    "after set_trim_mode('overwrite'), get must return 'overwrite'")
print("  ✓ set_trim_mode flips between the two enum values")

-- =============================================================================
-- 3. Enum guard (FR-009): invalid values assert, do not silently coerce.
-- =============================================================================
local function set_then_pcall(bad_value)
    return pcall(edit_mode.set_trim_mode, bad_value)
end

local ok, err = set_then_pcall("bogus")
assert(not ok, "set_trim_mode('bogus') must raise an assert")
assert(err and err:find("edit_mode"), string.format(
    "assert message must identify edit_mode as the source; got: %s",
    tostring(err)))

assert(not set_then_pcall(nil),    "set_trim_mode(nil) must raise an assert")
assert(not set_then_pcall(false),  "set_trim_mode(false) must raise an assert")
assert(not set_then_pcall(42),     "set_trim_mode(42) must raise an assert")
assert(not set_then_pcall("Ripple"), -- wrong case
    "set_trim_mode('Ripple') (wrong case) must raise an assert")

-- After a failed set, state must NOT have been silently coerced.
assert(edit_mode.get_trim_mode() == "overwrite", string.format(
    "after failed set_trim_mode, state must be unchanged; got %q",
    tostring(edit_mode.get_trim_mode())))
print("  ✓ enum guard rejects non-enum values; state unchanged on failure")

-- =============================================================================
-- 4. trim_mode_changed signal: payload is (new_mode, old_mode).
-- =============================================================================
local captured = {}
Signals.connect("trim_mode_changed", function(new_mode, old_mode)
    table.insert(captured, { new = new_mode, old = old_mode })
end)

edit_mode.set_trim_mode("ripple")
assert(#captured == 1, string.format(
    "set_trim_mode must emit trim_mode_changed exactly once; got %d emissions",
    #captured))
assert(captured[1].new == "ripple" and captured[1].old == "overwrite", string.format(
    "trim_mode_changed payload must be (new='ripple', old='overwrite'); got (new=%s, old=%s)",
    tostring(captured[1].new), tostring(captured[1].old)))

edit_mode.set_trim_mode("overwrite")
assert(#captured == 2 and captured[2].new == "overwrite" and captured[2].old == "ripple",
    "second set must emit with the swapped payload")
print("  ✓ trim_mode_changed signal fires with (new, old) payload")

-- =============================================================================
-- 5. Session-transient (FR-010): _reset_for_tests restores "overwrite".
-- =============================================================================
edit_mode.set_trim_mode("ripple")
assert(edit_mode.get_trim_mode() == "ripple", "fixture: set ripple before reset")

edit_mode._reset_for_tests()
assert(edit_mode.get_trim_mode() == "overwrite",
    "_reset_for_tests must restore initial 'overwrite' (session-transient semantics)")
print("  ✓ _reset_for_tests restores initial 'overwrite'")

-- =============================================================================
-- 6. ToggleTrimMode command flips via set_trim_mode (FR-011).
-- =============================================================================
-- Minimal DB so command_manager.init can resolve active project/sequence.
_G.qt_create_single_shot_timer = function() end
local database = require("core.database")
local TEST_DB = "/tmp/jve/test_edit_mode_toggle.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 10000, 0, '[]', '[]', '[]', 0, 0, 0);
]])

local command_manager = require("core.command_manager")
command_manager.init("seq", "proj")

edit_mode._reset_for_tests()  -- known starting state

local r = command_manager.execute_interactive("ToggleTrimMode", {})
assert(r and r.success, string.format(
    "ToggleTrimMode must succeed; got %s",
    tostring(r and r.error_message)))
assert(edit_mode.get_trim_mode() == "ripple",
    "after first ToggleTrimMode dispatch, mode must be 'ripple'")

r = command_manager.execute_interactive("ToggleTrimMode", {})
assert(r and r.success, "second ToggleTrimMode must succeed")
assert(edit_mode.get_trim_mode() == "overwrite",
    "after second ToggleTrimMode dispatch, mode must be back to 'overwrite'")
print("  ✓ ToggleTrimMode command flips the state on each dispatch")

-- =============================================================================
-- 7. ToggleTrimMode is non-undoable (FR-011): no history entry created.
--    Verified indirectly: command_manager.undo() should be a no-op AFTER a
--    ToggleTrimMode dispatch (the toggle is not on the undo stack).
-- =============================================================================
edit_mode._reset_for_tests()
command_manager.execute_interactive("ToggleTrimMode", {})
assert(edit_mode.get_trim_mode() == "ripple", "fixture: toggle to ripple")

-- Issue undo; mode must NOT revert (the toggle isn't undoable).
local _ = command_manager.undo()
assert(edit_mode.get_trim_mode() == "ripple",
    "command_manager.undo() must not revert ToggleTrimMode (undoable=false)")
print("  ✓ ToggleTrimMode is non-undoable (no history entry)")

print("\n✅ test_edit_mode_toggle.lua passed")
