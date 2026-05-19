#!/usr/bin/env luajit
--- Active panel (the one with the focus border) survives quit/reopen.
---
--- Domain contract: after the user quits the app with the project_browser
--- focused, the next launch of the same project opens with the project
--- browser focused — not whatever default the bootstrap path picks.
--- Saved in the project row (per-project preference), same place as
--- last_open_sequence_id.
---
--- This test exercises the WRITE side end-to-end against a real DB:
---   1. focus_manager.set_focused_panel(X) while a project is open
---   2. database.get_project_setting(pid, "last_focused_panel") == X
---
--- The read side (focus_manager.restore_persisted_focus) is covered by
--- the symmetric "round-trip" case below.

require("test_env")

print("=== test_focus_manager_persists_focused_panel.lua ===")

-- Use real core.qt_constants / core.ui_constants so timeline_state's
-- downstream requires succeed. Stub the Qt globals that focus_manager
-- calls without pcall (test_env makes unstubbed ones error).
_G.qt_set_focus_handler         = function() end
_G.qt_set_widget_attribute      = function() end
_G.qt_set_widget_contents_margins = function() end
_G.qt_set_widget_property       = function() end
_G.qt_set_widget_stylesheet     = function() end
_G.qt_set_focus                 = function() end
package.loaded["ui.selection_hub"] = {
    set_active_panel = function() end,
}

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager  = require("ui.focus_manager")

local DB = "/tmp/jve/test_focus_manager_persists_focused_panel.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))
local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES ('rec', 'p', 'Rec', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 0, 300, %d, %d);
]], now, now, now, now))

timeline_state.reset()
timeline_state.init("rec", "p")

-- Register a couple panels so set_focused_panel can transition.
focus_manager.register_panel("project_browser", {_id=1}, nil, "Project Browser")
focus_manager.register_panel("inspector",       {_id=2}, nil, "Inspector")
focus_manager.register_panel("timeline",        {_id=3}, nil, "Timeline")

-- ── Case 1: focus change writes last_focused_panel into project settings ──
focus_manager.set_focused_panel("project_browser")
local saved = database.get_project_setting("p", "last_focused_panel")
assert(saved == "project_browser", string.format(
    "set_focused_panel('project_browser') must persist last_focused_panel='project_browser'; "
    .. "got %s", tostring(saved)))
print("  ✓ set_focused_panel writes last_focused_panel")

focus_manager.set_focused_panel("inspector")
saved = database.get_project_setting("p", "last_focused_panel")
assert(saved == "inspector", string.format(
    "subsequent focus change must overwrite last_focused_panel='inspector'; "
    .. "got %s", tostring(saved)))
print("  ✓ subsequent focus change overwrites the setting")

-- ── Case 2: restore_persisted_focus reads the setting + focuses that panel ──
-- Simulate a quit-and-reopen: clear in-memory focus, then call the
-- restore path that layout.lua invokes after sequence restore.
focus_manager.set_focused_panel(nil)  -- defocus all
assert(focus_manager.get_focused_panel() == nil,
    "fixture: defocused before restore")

focus_manager.restore_persisted_focus("p")
assert(focus_manager.get_focused_panel() == "inspector", string.format(
    "restore_persisted_focus must focus the saved panel; got %s",
    tostring(focus_manager.get_focused_panel())))
print("  ✓ restore_persisted_focus focuses the saved panel")

-- ── Case 3: restore is a no-op when the saved panel id is not registered ──
-- A renamed/removed panel mustn't crash startup. Focus stays unchanged.
database.set_project_setting("p", "last_focused_panel", "ghost_panel")
focus_manager.set_focused_panel("timeline")
focus_manager.restore_persisted_focus("p")
assert(focus_manager.get_focused_panel() == "timeline", string.format(
    "restore_persisted_focus must NOT change focus when the saved panel "
    .. "id is unknown; got %s", tostring(focus_manager.get_focused_panel())))
print("  ✓ restore_persisted_focus is a no-op for unknown panel id")

print("\n✅ test_focus_manager_persists_focused_panel.lua passed")
