require('test_env')

-- JKL keyboard shortcut dispatch test.
-- Verifies that literal Qt key codes J/K/L dispatch correct shuttle commands.
-- Uses LITERAL Qt key codes (not keyboard_constants) to catch wrong-constant bugs.
-- Uses REAL timeline_state — no mock.
-- command_manager mock is justified: test tracks dispatched command names, not execution.

print("=== Test JKL Keyboard Shortcuts ===")

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Mock panel_manager (Qt dependency)
package.loaded["ui.panel_manager"] = {
    toggle_active_panel = function() end,
    get_active_sequence_monitor = function() return nil end,
}

-- Set up database for real timeline_state
local database = require("core.database")
local command_manager = require("core.command_manager")

local TEST_DB = "/tmp/jve/test_jkl_keyboard.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Seq', 'nested', 24, 1, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d
    );
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Init real timeline_state from database
command_manager.init('seq1', 'proj1')

-- Load real modules
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")
local timeline_state = require("ui.timeline.timeline_state")

-- ── Literal Qt key codes ──
local QT_KEY_J = 74
local QT_KEY_K = 75
local QT_KEY_L = 76

-- Mock command_manager for dispatch tracking (justified: testing routing, not execution)
local dispatched = {}
local mock_cm = {
    execute_interactive = function(cmd)
        dispatched[#dispatched + 1] = cmd
        return { success = true }
    end,
    get_executor = function() return function() end end,
    peek_command_event_origin = function() return nil end,
    begin_command_event = function() end,
    end_command_event = function() end,
}

local function reset()
    dispatched = {}
    focus_manager.set_focused_panel("timeline")
    keyboard_shortcuts.init(mock_cm,
        { add_selected_to_timeline = function() end },
        { is_dragging = function() return false end })
end

local function find_cmd(name)
    for _, cmd in ipairs(dispatched) do
        if cmd == name then return true end
    end
    return false
end

-- Tests 1-3: JKL are NOT dispatched by the Lua residual handler.
-- QShortcut handles JKL dispatch; the residual handler returns false.
print("\nTest 1: J not handled by residual handler (QShortcut handles it)")
reset()
local handled = keyboard_shortcuts.handle_key({ key = QT_KEY_J, modifiers = 0, text = "j", focus_widget_is_text_input = 0 })
assert(not handled, "J must not be handled by residual handler")
assert(not find_cmd("ShuttleReverse"), "ShuttleReverse must not dispatch via residual handler")
print("  ✓ J not handled by residual handler")

print("\nTest 2: K not handled by residual handler")
reset()
handled = keyboard_shortcuts.handle_key({ key = QT_KEY_K, modifiers = 0, text = "k", focus_widget_is_text_input = 0 })
assert(not handled, "K must not be handled by residual handler")
print("  ✓ K not handled by residual handler")

print("\nTest 3: L not handled by residual handler")
reset()
handled = keyboard_shortcuts.handle_key({ key = QT_KEY_L, modifiers = 0, text = "l", focus_widget_is_text_input = 0 })
assert(not handled, "L must not be handled by residual handler")
print("  ✓ L not handled by residual handler")

print("\nTest 4: J in text field not handled (QShortcut text protection)")
reset()
keyboard_shortcuts.handle_key({ key = QT_KEY_J, modifiers = 0, text = "j", focus_widget_is_text_input = true })
assert(not find_cmd("ShuttleReverse"), "J should not dispatch in text field")
print("  ✓ J in text field passes through")

print("\nTest 5: handle_key_release exists and returns false")
assert(type(keyboard_shortcuts.handle_key_release) == "function", "handle_key_release should exist")
local result = keyboard_shortcuts.handle_key_release({ key = QT_KEY_K })
assert(result == false, "handle_key_release should return false")
print("  ✓ handle_key_release(K) returns false")

-- ═══════════════════════════════════════════════════════════════════════════
-- Tests 6-8: focus_outside_main_window TOML fallback
-- When focus is in a floating window (History panel), QShortcuts can't resolve.
-- The C++ GlobalKeyFilter claims all keys and sets focus_outside_main_window=true.
-- The Lua handler must fall back to TOML registry lookup in this case.
-- ═══════════════════════════════════════════════════════════════════════════

print("\nTest 6: TOML-bound key dispatches when focus_outside_main_window=true")
reset()
-- Cmd+Z is TOML-bound to Undo. With focus outside main window, the Lua
-- handler must fall back to TOML registry and dispatch it.
local QT_KEY_Z = 90
local CMD_MOD = 0x04000000  -- Qt::ControlModifier (Cmd on macOS)
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_Z, modifiers = CMD_MOD, text = "z",
    focus_widget_is_text_input = 0,
    focus_outside_main_window = true,
})
assert(handled, "Cmd+Z must be handled via TOML fallback when focus_outside_main_window")
print("  ✓ Cmd+Z dispatched via TOML fallback")

print("\nTest 7: Same TOML-bound key NOT dispatched when focus inside main window")
reset()
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_Z, modifiers = CMD_MOD, text = "z",
    focus_widget_is_text_input = 0,
    focus_outside_main_window = false,
})
assert(not handled, "Cmd+Z must NOT be handled by Lua when focus inside main window (QShortcut handles it)")
print("  ✓ Cmd+Z not handled by Lua when focus inside main window")

print("\nTest 8: JKL still dispatched via TOML fallback when focus_outside_main_window=true")
reset()
-- Display-only floating windows like the History panel are transparent to
-- shortcuts: the user expects J to drive the timeline shuttle as if the
-- floating window weren't there. focus_outside_main_window routes through
-- the Lua fallback using focus_manager's last main-window panel — that
-- "stale" value is the correct semantic for display-only windows.
-- find_dialog's text input is protected separately by the is_text_editing_key
-- guard upstream, not here.
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_J, modifiers = 0, text = "j",
    focus_widget_is_text_input = 0,
    focus_outside_main_window = true,
})
assert(handled, "J must be dispatched via TOML fallback when focus_outside_main_window")
assert(find_cmd("ShuttleReverse"), "ShuttleReverse should dispatch via TOML fallback")
print("  ✓ J dispatches ShuttleReverse via TOML fallback")

print("\n✅ test_jkl_keyboard_shortcuts.lua passed")
