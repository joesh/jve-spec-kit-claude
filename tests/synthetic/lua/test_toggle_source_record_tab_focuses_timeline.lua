#!/usr/bin/env luajit
--- ToggleSourceRecordTab is a keyboard-driven tab swap. After it runs,
--- the user is looking at the timeline panel — keystrokes (Space, J/K/L,
--- marks) should land there immediately. Focus must move to the
--- timeline panel even when invoked from the project browser /
--- inspector / source viewer.

require("test_env")

_G.qt_create_single_shot_timer = function(_d, cb) if cb then cb() end end
_G.qt_set_focus_handler         = function() end
_G.qt_set_widget_attribute      = function() end
_G.qt_set_widget_contents_margins = function() end
_G.qt_set_widget_property       = function() end
_G.qt_set_widget_stylesheet     = function() end
_G.qt_set_focus                 = function() end

package.loaded["ui.selection_hub"] = { set_active_panel = function() end }

print("=== test_toggle_source_record_tab_focuses_timeline.lua ===")

local database        = require("core.database")
local timeline_state  = require("ui.timeline.timeline_state")
local focus_manager   = require("ui.focus_manager")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_toggle_source_record_tab_focuses_timeline.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))
local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d)
]], now, now))
conn:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES ('rec', 'p', 'Rec', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 300, %d, %d)
]], now, now))

timeline_state.reset()
timeline_state.init("rec", "p")
command_manager.init("rec", "p")

focus_manager.register_panel("timeline",        {_id=1}, nil, "Timeline")
focus_manager.register_panel("project_browser", {_id=2}, nil, "Project Browser")

-- Start with focus elsewhere (the bug scenario: keystroke from browser).
focus_manager.set_focused_panel("project_browser")
assert(focus_manager.get_focused_panel() == "project_browser",
    "fixture: focus must start on project_browser")

-- Execute the command. From the record tab with no source loaded the
-- toggle blanks the body (source side has nothing to swap to), but the
-- focus-side guarantee MUST hold regardless of which branch ran.
local ok, err = command_manager.execute("ToggleSourceRecordTab", {})
assert(ok, string.format("ToggleSourceRecordTab execute failed: %s", tostring(err)))

assert(focus_manager.get_focused_panel() == "timeline", string.format(
    "after ToggleSourceRecordTab the timeline panel must be focused; got %s",
    tostring(focus_manager.get_focused_panel())))
print("  ✓ ToggleSourceRecordTab moves focus to timeline panel")

print("\n✅ test_toggle_source_record_tab_focuses_timeline.lua passed")
