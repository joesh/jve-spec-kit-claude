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
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Seq', 'timeline', 24, 1, 48000,
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

function command_manager_stub.execute_ui(command_name)
    table.insert(command_manager_stub.executed_commands, command_name)
    return {success = true}
end

function command_manager_stub.get_executor(command_name) -- luacheck: ignore 212
    return function() end
end

function command_manager_stub.peek_command_event_origin()
    return nil
end

function command_manager_stub.begin_command_event() end
function command_manager_stub.end_command_event() end

local timeline_panel_stub = {
    is_dragging = function() return false end,
    focus_timeline_view = function() return true end,
    focus_timecode_entry = function() return true end,
    cancel_timecode_calls = 0,
}
function timeline_panel_stub.cancel_timecode_entry()
    timeline_panel_stub.cancel_timecode_calls = timeline_panel_stub.cancel_timecode_calls + 1
    return true
end

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
    local project_browser_stub = {
        add_selected_to_timeline = function() end,
    }
    keyboard_shortcuts.init(timeline_state, command_manager_stub, project_browser_stub, timeline_panel_stub)
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

-- Test 3: Text inputs bypass timeline shortcuts
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_I,
    modifiers = QT_MOD_NONE,
    text = "i",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Character keys should pass through when typing in a text field")
assert_false(find_command("SetMarkIn"), "SetMarkIn should not dispatch while typing in text field")

-- Test 4: Undo is still handled as a global shortcut (via TOML dispatch)
reset_environment()
focus_manager.set_focused_panel("inspector")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_Z,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Cmd/Ctrl+Z should be treated as a global command")
assert_true(find_command("Undo"), "Cmd+Z should dispatch Undo command")

-- Test 5: Return activates browser selection only when browser focused
reset_environment()
focus_manager.set_focused_panel("project_browser")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_RETURN,
    modifiers = QT_MOD_NONE,
    text = "\n",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Return should trigger browser activation when browser focused")
assert_equal(command_manager_stub.executed_commands[#command_manager_stub.executed_commands], "ActivateBrowserSelection", "Browser activation command should be executed")

-- Test 6: Return ignored when browser not focused
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_RETURN,
    modifiers = QT_MOD_NONE,
    text = "\n",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Return should not be handled when browser not focused")
assert_equal(#command_manager_stub.executed_commands, 0, "No commands should execute when Return ignored")

-- Test 7: Cmd+A in text field should NOT dispatch SelectAll command
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_A,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+A must pass through to text field, not dispatch SelectAll")
assert_false(find_command("SelectAll"), "SelectAll must not fire while typing in text field")

-- Test 8: Cmd+Z in text field should NOT dispatch Undo command
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_Z,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+Z must pass through to text field for inline undo")
assert_false(find_command("Undo"), "Undo must not fire while typing in text field")

-- Test 9: Cmd+B in text field should NOT dispatch Blade command
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_B,
    modifiers = QT_MOD_CONTROL,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+B must pass through to text field, not dispatch Blade")
assert_false(find_command("Blade"), "Blade must not fire while typing in text field")

-- Test 10: focus_widget_is_text_input=0 (C++ false) must NOT bypass
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_I,
    modifiers = QT_MOD_NONE,
    text = "i",
    focus_widget_is_text_input = 0,  -- C++ lua_pushboolean(false) = 0
})
assert_true(handled, "focus_widget_is_text_input=0 must not trigger text bypass")
assert_true(find_command("SetMark"), "SetMark must dispatch when focus_widget_is_text_input=0")

-- Test 11: focus_widget_is_text_input=nil (missing field) must NOT bypass
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_I,
    modifiers = QT_MOD_NONE,
    text = "i",
    -- focus_widget_is_text_input omitted entirely
})
assert_true(handled, "missing focus_widget_is_text_input must not trigger text bypass")
assert_true(find_command("SetMark"), "SetMark must dispatch when focus_widget_is_text_input is nil")

-- Test 12: Arrow keys in text field must pass through (not start arrow_repeat)
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = QT_KEY_LEFT,
    modifiers = QT_MOD_NONE,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Left arrow must pass through to text field for cursor movement")
assert_false(find_command("MovePlayhead"), "MovePlayhead must not fire while in text field")

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

print("✅ keyboard focus routing tests passed")
