#!/usr/bin/env luajit
--- Regression: Copy with nothing selected must return success=true, not
--- success=false. Returning false triggered the QShortcut handler's
--- fail-fast assert ("shortcut handler Copy returned success=false"),
--- crashing on Cmd+C whenever nothing was on the clipboard stack.
---
--- Domain contract: Copy on an empty selection is a no-op (user pressed
--- the key; there was nothing to copy). That is a successful no-op, not
--- a command failure. The QShortcut assert fires only on *unexpected*
--- command failures, not on "nothing to do" user states.

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end

print("=== test_copy_empty_selection_is_noop.lua ===")

local database        = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_copy_empty_selection_is_noop.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))

local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        video_scroll_offset, audio_scroll_offset,
        created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Main', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 300, 0, 0, %d, %d);
]], now, now, now, now))

command_manager.init("seq1", "proj1")
command_manager.begin_command_event("ui")

-- Execute Copy with no timeline selection (clipboard_actions.copy() returns
-- false, "No timeline clips selected"). The command must return success=true.
local result = command_manager.execute_interactive("Copy", {
    project_id  = "proj1",
    sequence_id = "seq1",
})

command_manager.end_command_event()

-- This assert verifies the regression: success=false here is what triggered
-- the QShortcut handler crash. After the fix, Copy must report success on
-- empty selection.
assert(type(result) == "table",
    "Copy must return a result table, got " .. type(result))
assert(result.success == true, string.format(
    "Copy on empty selection must succeed (no-op). "
    .. "success=false triggers QShortcut fail-fast assert on Cmd+C. "
    .. "Got success=%s", tostring(result and result.success)))

print("  ✓ Copy on empty selection returns success=true (no spurious assert)")
print("\n✅ test_copy_empty_selection_is_noop.lua passed")
