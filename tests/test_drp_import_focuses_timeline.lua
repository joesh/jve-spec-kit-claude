#!/usr/bin/env luajit
--- After DRP import lands a record sequence, the next thing the user
--- does is play it / cut on it — so focus must move to the timeline
--- panel automatically. Without this, focus stays in the project
--- browser and Space/J/K/L route there instead.
---
--- Tested via the post-import refresh helper. The full DRP parse path
--- is exercised elsewhere; here we pin "after refresh, if there is an
--- active sequence, the focused panel is the timeline."

require("test_env")

_G.qt_set_focus_handler          = function() end
_G.qt_set_widget_attribute       = function() end
_G.qt_set_widget_contents_margins= function() end
_G.qt_set_widget_property        = function() end
_G.qt_set_widget_stylesheet      = function() end
_G.qt_set_focus                  = function() end

package.loaded["ui.selection_hub"] = { set_active_panel = function() end }
package.loaded["ui.ui_state"] = {
    get_project_browser = function() return { refresh = function() end } end,
}

print("=== test_drp_import_focuses_timeline.lua ===")

local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager  = require("ui.focus_manager")
local importer       = require("core.commands.import_resolve_project")

assert(type(importer.focus_post_import) == "function",
    "core.commands.import_resolve_project must expose focus_post_import for testing + reuse")

local DB = "/tmp/jve/test_drp_import_focuses_timeline.db"
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

focus_manager.register_panel("timeline",        {_id=1}, nil, "Timeline")
focus_manager.register_panel("project_browser", {_id=2}, nil, "Project Browser")

-- ── Case 1: active sequence exists → timeline focused ──
focus_manager.set_focused_panel("project_browser")
importer.focus_post_import("p")
assert(focus_manager.get_focused_panel() == "timeline", string.format(
    "DRP import with an active sequence must focus the timeline; got %s",
    tostring(focus_manager.get_focused_panel())))
print("  ✓ with active sequence → focus moves to timeline")

-- ── Case 2: no active sequence (browser-only import) → focus unchanged ──
timeline_state.clear()
focus_manager.set_focused_panel("project_browser")
importer.focus_post_import("p")
assert(focus_manager.get_focused_panel() == "project_browser", string.format(
    "DRP import with no active sequence must NOT steal focus; got %s",
    tostring(focus_manager.get_focused_panel())))
print("  ✓ with no active sequence → focus unchanged")

print("\n✅ test_drp_import_focuses_timeline.lua passed")
