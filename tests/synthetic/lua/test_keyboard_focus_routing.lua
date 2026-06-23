#!/usr/bin/env luajit
-- Tests keyboard shortcut focus routing and text-field bypass.
-- Uses LITERAL Qt key codes (not keyboard_constants) to catch wrong-constant bugs.
-- Uses REAL timeline_state — no mock.
-- command_manager mock is justified: test tracks dispatched command names, not execution.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Mock panel_manager (Qt dependency)
package.loaded["ui.panel_manager"] = {
    toggle_active_panel = function() end,
    get_active_sequence_monitor = function() return nil end,
}

local timeline_panel_stub
timeline_panel_stub = {
    is_dragging = function() return false end,
    focus_timeline_view = function() return true end,
    focus_timecode_entry = function() return true end,
    cancel_timecode_calls = 0,
    cancel_timecode_entry = function()
        timeline_panel_stub.cancel_timecode_calls = timeline_panel_stub.cancel_timecode_calls + 1
        return true
    end
}
package.loaded["ui.timeline.timeline_panel"] = timeline_panel_stub

local project_browser_stub
project_browser_stub = {
    add_selected_to_timeline = function() end,
    find_bar = nil,  -- find bar state for Escape dismiss test
    hide_find_bar = function() end,
}
package.loaded["ui.project_browser"] = project_browser_stub

-- Mock fullscreen_viewer
package.loaded["ui.fullscreen_viewer"] = {
    is_active = function() return false end,
    exit = function() end,
}

-- Set up database for real timeline_state
local database = require("core.database")
local command_manager = require("core.command_manager")

local TEST_DB = "/tmp/jve/test_keyboard_focus_routing.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")
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

-- Init real timeline_state from database
command_manager.init('seq1', 'proj1')

local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")
local selection_hub = require("ui.selection_hub")
local timeline_state = require("ui.timeline.timeline_state")

-- ── Literal Qt key codes (ground truth from Qt::Key enum) ──
local QT_KEY_LEFT      = 16777234   -- 0x01000012
local QT_KEY_RIGHT     = 16777236   -- 0x01000014
local QT_KEY_I         = 73
local QT_KEY_Z         = 90
local QT_KEY_A         = 65
local QT_KEY_B         = 66
local QT_KEY_RETURN    = 16777220   -- 0x01000004
local QT_KEY_ESCAPE    = 16777216   -- 0x01000000

local QT_MOD_NONE    = 0
local QT_MOD_CONTROL = 0x04000000  -- Cmd on macOS

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

local function assert_true(value, message)
    if not value then
        error(message or "Assertion failed: expected truthy value")
    end
end

local function assert_false(value, message)
    if value then
        error(message or "Assertion failed: expected falsy value")
    end
end

-- Mock command_manager for dispatch tracking (justified: testing routing, not execution)
local command_manager_stub = {
    undo_calls = 0,
    redo_calls = 0,
    current_sequence_number = 0,
    executed_commands = {},
}

function command_manager_stub.undo()
    command_manager_stub.undo_calls = command_manager_stub.undo_calls + 1
    if command_manager_stub.current_sequence_number > 0 then
        command_manager_stub.current_sequence_number = command_manager_stub.current_sequence_number - 1
    end
    return {success = true}
end

function command_manager_stub.redo()
    command_manager_stub.redo_calls = command_manager_stub.redo_calls + 1
    command_manager_stub.current_sequence_number = command_manager_stub.current_sequence_number + 1
    return {success = true}
end

function command_manager_stub.get_stack_state()
    return {current_sequence_number = command_manager_stub.current_sequence_number}
end

function command_manager_stub.execute(command_arg)
    local command_name
    if type(command_arg) == "string" then
        command_name = command_arg
    elseif type(command_arg) == "table" then
        command_name = command_arg.type or command_arg.command_type or "unknown"
    else
        command_name = tostring(command_arg)
    end
    table.insert(command_manager_stub.executed_commands, command_name)
    return {success = true}
end

function command_manager_stub.execute_interactive(command_name)
    table.insert(command_manager_stub.executed_commands, command_name)
    if command_name == "Cancel" then
        local Cancel = require("core.commands.cancel")
        return { success = Cancel.execute({}) }
    end
    return {success = true}
end

function command_manager_stub.get_executor(command_name) -- luacheck: ignore 212
    return function() end
end

function command_manager_stub.get_spec(command_name)
    -- Forward to the real SPEC (single source of truth) so SPEC.when()
    -- decides consumption against the test's stubbed surfaces (fullscreen,
    -- find dialog, find bar, timeline panel) — same code path as production.
    if command_name == "Cancel" then
        return require("core.commands.cancel").SPEC
    end
    return nil
end

function command_manager_stub.peek_command_event_origin()
    return nil
end

function command_manager_stub.begin_command_event() end
function command_manager_stub.end_command_event() end

local function reset_environment()
    selection_hub._reset_for_tests()
    command_manager_stub.undo_calls = 0
    command_manager_stub.redo_calls = 0
    command_manager_stub.current_sequence_number = 0
    command_manager_stub.executed_commands = {}
    timeline_panel_stub.cancel_timecode_calls = 0
    -- Real timeline_state: set playhead to known position for tracking
    timeline_state.set_playhead_position(100)
    focus_manager.set_focused_panel(nil)
    project_browser_stub.find_bar = nil
    project_browser_stub.hide_find_bar = function() end
    keyboard_shortcuts.init(command_manager_stub, project_browser_stub, timeline_panel_stub)
end

local function find_command(name)
    for _, cmd in ipairs(command_manager_stub.executed_commands) do
        if cmd == name then return true end
    end
    return false
end

-- Test 1: Arrow keys ignored when timeline does not have focus
reset_environment()
focus_manager.set_focused_panel("inspector")
local playhead_before = timeline_state.get_playhead_position()
local handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_LEFT,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Left arrow should not be handled when inspector has focus")
assert_equal(timeline_state.get_playhead_position(), playhead_before,
    "Playhead must not move without timeline focus")

-- Test 2: Arrow keys move playhead when timeline has focus
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_RIGHT,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Right arrow should be handled when timeline has focus")
assert_true(find_command("MovePlayhead"), "Right arrow should dispatch MovePlayhead command")

-- Test 3: Non-residual keys not handled by Lua (QShortcut handles them)
-- I key is dispatched by QShortcut, not the Lua residual handler
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_I,
    modifiers = QT_MOD_NONE,
    text = "i",
    focus_widget_is_text_input = false,
})
assert_false(handled, "I key must not be handled by residual handler (QShortcut handles it)")

-- Test 4: Cmd+Z not handled by Lua (QShortcut handles global shortcuts)
reset_environment()
focus_manager.set_focused_panel("inspector")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_Z,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Cmd+Z must not be handled by residual handler (QShortcut handles it)")

-- Test 5: Return not handled by Lua (tree keymap + PanelFocusTrap handle it)
reset_environment()
focus_manager.set_focused_panel("project_browser")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_RETURN,
    modifiers = QT_MOD_NONE,
    text = "\n",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Return must not be handled by residual handler (native widget handles it)")

-- Test 6: Return not handled regardless of panel
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_RETURN,
    modifiers = QT_MOD_NONE,
    text = "\n",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Return must not be handled by residual handler in any panel")

-- Test 7: Cmd+A not handled by Lua (QShortcut or text widget handles it)
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_A,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+A must not be handled by residual handler")

-- Test 8: Cmd+Z not handled by Lua (text field or QShortcut handles it)
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_Z,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+Z must not be handled by residual handler in text field")

-- Test 9: Cmd+B not handled by Lua
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_B,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+B must not be handled by residual handler")

-- Test 10: Left arrow in text field bypassed for cursor movement.
-- Left matches QKeySequence::MoveToPreviousChar — the C++ helper
-- `is_text_editing_key` returns true for it, and the general text-input
-- guard in the Lua handler defers to the widget.
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_LEFT,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = true,
    is_text_editing_key = true,
})
assert_false(handled, "Left arrow must pass through to text field for cursor movement")
assert_false(find_command("MovePlayhead"), "MovePlayhead must not fire while in text field")

-- Test 11: Residual key (Left arrow) NOT bypassed when text_input=0 (C++ false)
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_LEFT,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = 0,  -- C++ lua_pushboolean(false) = 0
})
assert_true(handled, "Left arrow must start repeat when focus_widget_is_text_input=0")
assert_true(find_command("MovePlayhead"), "MovePlayhead must dispatch when text_input=0")

-- Test 13: Escape in text field cancels timecode entry
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_ESCAPE,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = true,
})
assert_true(handled, "Escape in text field must be consumed (not passed through)")
assert_equal(timeline_panel_stub.cancel_timecode_calls, 1,
    "Escape in text field must call cancel_timecode_entry")
assert_equal(#command_manager_stub.executed_commands, 0,
    "Escape in text field must not dispatch any command")

-- Test 14: Escape outside text field is NOT consumed (passes through to Qt)
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_ESCAPE,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Escape outside text field should not be consumed")
assert_equal(timeline_panel_stub.cancel_timecode_calls, 0,
    "cancel_timecode_entry must not be called outside text field")

-- Test 15: Escape dismisses any visible find bar regardless of which panel owns it.
local find_chrome = require("ui.find_chrome")
local function inject_visible_chrome()
    find_chrome._reset_for_test()
    local fake = { visible = true }
    function fake:hide() self.visible = false end
    find_chrome._register_for_test(fake)
    return fake
end

reset_environment()
local fake_chrome = inject_visible_chrome()
focus_manager.set_focused_panel("project_browser")

handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_ESCAPE,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Escape must be consumed when a find_chrome surface is visible")
assert_false(fake_chrome.visible,
    "Escape must hide the visible find_chrome surface")

-- Test 16: Escape dismisses find_chrome even when text field is focused.
-- The chrome's QLineEdit doesn't do anything useful with native Escape, so
-- Esc must route through the Cancel command to dismiss the surface.
reset_environment()
fake_chrome = inject_visible_chrome()
focus_manager.set_focused_panel("project_browser")

handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_ESCAPE,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = true,
})
assert_true(handled,
    "Escape with find_chrome visible must be consumed even with text input focused")
assert_false(fake_chrome.visible,
    "Escape with find_chrome visible + text input focus must hide the surface")

print("✅ keyboard focus routing tests passed")
