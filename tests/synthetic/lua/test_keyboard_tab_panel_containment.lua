#!/usr/bin/env luajit
-- Black-box invariant: Tab/Backtab never escapes one panel to another. The
-- dispatcher must consume (return true) so Qt's native focusNextPrevChild
-- doesn't fire. Exception: when focus is on a floating-window text field
-- (find_dialog), native field cycling IS the right behavior — return false.
--
-- This test drives keyboard_shortcuts.handle_key with synthetic Tab events
-- in each case and asserts the return value. Pre-rewrite this was a regex
-- grep over keyboard_shortcuts.lua — it pinned source formatting and would
-- pass with the rule violated as long as the comment text matched.

require('test_env')

_G.qt_create_single_shot_timer = function() end

-- Stubs for Qt-dependent dispatchers reachable from handle_key. Tab dispatch
-- itself does NOT route through these; they're loaded as deps.
package.loaded["ui.panel_manager"] = {
    toggle_active_panel = function() end,
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.timeline.timeline_panel"] = {
    is_dragging = function() return false end,
    focus_timeline_view = function() return true end,
    focus_timecode_entry = function() return true end,
    cancel_timecode_entry = function() return false end,
}
package.loaded["ui.project_browser"] = {
    add_selected_to_timeline = function() end,
    find_bar = nil,
    hide_find_bar = function() end,
}
package.loaded["ui.fullscreen_viewer"] = {
    is_active = function() return false end,
    exit = function() end,
}

local database = require("core.database")
local command_manager = require("core.command_manager")

local TEST_DB = "/tmp/jve/test_keyboard_tab_panel_containment.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Seq', 'sequence', 24, 1, 48000,
        1920, 1080, 0, 240, 100, '[]', '[]', '[]', 0, %d, %d
    );
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

command_manager.init('seq1', 'proj1')

local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")

keyboard_shortcuts.init(command_manager, nil,
    package.loaded["ui.timeline.timeline_panel"])

-- Literal Qt key codes
local QT_KEY_TAB     = 16777217  -- 0x01000001
local QT_MOD_NONE    = 0
local QT_MOD_SHIFT   = 0x02000000

-- The Tab branch reads focused_panel via focus_manager. Force a known
-- non-nil panel so the dispatcher doesn't assert mid-test.
focus_manager.set_focused_panel("timeline_monitor")

print("=== Tab/Backtab panel-containment invariant ===\n")

local pass, fail = 0, 0
local function check(label, ok)
    if ok then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

-- Case 1: Tab inside main window must be consumed (return true) — never
-- false, which would let Qt's native focusNextPrevChild escape the panel.
local handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_TAB,
    modifiers = QT_MOD_NONE,
    text = "\t",
    focus_widget_is_text_input = false,
    focus_outside_main_window = false,
})
check("Tab in main window is consumed (true)", handled == true)

-- Case 2: Shift+Tab in main window must also be consumed. (Qt sends a
-- distinct Backtab key code on Shift+Tab in some contexts; the dispatcher
-- branches on `key == KEY.Tab or key == KEY.Backtab`. We exercise the
-- Shift modifier path here.)
local handled_shift = keyboard_shortcuts.handle_key({
    key = QT_KEY_TAB,
    modifiers = QT_MOD_SHIFT,
    text = "\t",
    focus_widget_is_text_input = false,
    focus_outside_main_window = false,
})
check("Shift+Tab in main window is consumed (true)", handled_shift == true)

-- Case 3: Tab on floating-window text field (find_dialog) must return false
-- so Qt's native field cycling fires — the only legitimate Tab escape.
local handled_dlg = keyboard_shortcuts.handle_key({
    key = QT_KEY_TAB,
    modifiers = QT_MOD_NONE,
    text = "\t",
    focus_widget_is_text_input = true,
    focus_outside_main_window = true,
})
check("Tab on floating text input lets Qt cycle (false)", handled_dlg == false)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_keyboard_tab_panel_containment.lua passed")
