#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

local keyboard_shortcuts = require("core.keyboard_shortcuts")
local focus_manager = require("ui.focus_manager")
local selection_hub = require("ui.selection_hub")

local KEY = keyboard_shortcuts.KEY
local MOD = keyboard_shortcuts.MOD

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

local timeline_state = {}
local timeline_moves = {}
local timeline_marks = { last_in = nil, last_out = nil }

function timeline_state.get_sequence_frame_rate()
    return 24
end

function timeline_state.get_playhead_position()
    return timeline_state.playhead or 0
end

function timeline_state.set_playhead_position(value)
    local numeric = value
    if type(value) == "table" and value.frames then
        numeric = value.frames
    end
    timeline_state.playhead = numeric
    table.insert(timeline_moves, numeric)
end

function timeline_state.get_mark_in()
    return timeline_marks.last_in
end

function timeline_state.get_mark_out()
    return timeline_marks.last_out
end

-- Marks now go through commands (SetMarkIn, SetMarkOut, ClearMarks)
-- No mock setters needed — mark dispatch is verified via command_manager_stub.executed_commands

function timeline_state.get_clips()
    return {}
end

function timeline_state.get_selected_clips()
    return {}
end

function timeline_state.get_selected_edges()
    return {}
end

function timeline_state.get_clips_at_time()
    return {}
end

function timeline_state.get_track_by_id()
    return nil
end

function timeline_state.get_track_index()
    return nil
end

function timeline_state.get_sequence_id()
    return "default_sequence"
end

function timeline_state.get_project_id()
    return "default_project"
end

function timeline_state.get_default_video_track_id()
    return "video1"
end

function timeline_state.get_all_tracks()
    return {}
end

function timeline_state.set_selection()
end

function timeline_state.set_mark_range()
end

function timeline_state.set_viewport_duration_frames_value()
end

function timeline_state.set_viewport_start_value()
end

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

function command_manager_stub.execute_ui(command_name, params)
    table.insert(command_manager_stub.executed_commands, command_name)
    return {success = true}
end

function command_manager_stub.get_executor(command_name)
    -- Return a dummy executor so TOML dispatch works
    return function() end
end

function command_manager_stub.peek_command_event_origin()
    return nil
end

function command_manager_stub.begin_command_event() end
function command_manager_stub.end_command_event() end

local timeline_panel_stub = {
    is_dragging = function()
        return false
    end,
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
    timeline_state.playhead = 100
    timeline_moves = {}
    timeline_marks = { last_in = nil, last_out = nil }
    focus_manager.set_focused_panel(nil)
    local project_browser_stub = {
        add_selected_to_timeline = function() end,
    }
    keyboard_shortcuts.init(timeline_state, command_manager_stub, project_browser_stub, timeline_panel_stub)
end

-- Test 1: Arrow keys ignored when timeline does not have focus
reset_environment()
focus_manager.set_focused_panel("inspector")
local handled = keyboard_shortcuts.handle_key({
    key = KEY.Left,
    modifiers = MOD.NoModifier,
    text = "",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Left arrow should not be handled when inspector has focus")
assert_equal(#timeline_moves, 0, "Playhead must not move without timeline focus")

-- Test 2: Arrow keys move playhead when timeline has focus
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Right,
    modifiers = MOD.NoModifier,
    text = "",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Right arrow should be handled when timeline has focus")
-- Arrow keys dispatch MovePlayhead command via arrow_repeat
local found_move = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "MovePlayhead" then found_move = true; break end
end
assert_true(found_move, "Right arrow should dispatch MovePlayhead command")

-- Test 3: Text inputs bypass timeline shortcuts
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.I,
    modifiers = MOD.NoModifier,
    text = "i",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Character keys should pass through when typing in a text field")
-- Marks now dispatched via commands — verify no SetMarkIn was executed
local found_mark_in = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "SetMarkIn" then found_mark_in = true; break end
end
assert_false(found_mark_in, "SetMarkIn should not dispatch while typing in text field")

-- Test 4: Undo is still handled as a global shortcut (via TOML dispatch)
reset_environment()
focus_manager.set_focused_panel("inspector")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Z,
    modifiers = MOD.Control,  -- Qt: Command key = ControlModifier on macOS
    text = "",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Cmd/Ctrl+Z should be treated as a global command")
local found_undo = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "Undo" then found_undo = true; break end
end
assert_true(found_undo, "Cmd+Z should dispatch Undo command")

-- Test 5: Return activates browser selection only when browser focused
reset_environment()
focus_manager.set_focused_panel("project_browser")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Return,
    modifiers = MOD.NoModifier,
    text = "\n",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Return should trigger browser activation when browser focused")
assert_equal(command_manager_stub.executed_commands[#command_manager_stub.executed_commands], "ActivateBrowserSelection", "Browser activation command should be executed")

-- Test 6: Return ignored when browser not focused
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Return,
    modifiers = MOD.NoModifier,
    text = "\n",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Return should not be handled when browser not focused")
assert_equal(#command_manager_stub.executed_commands, 0, "No commands should execute when Return ignored")

-- Test 7: Cmd+A in text field should NOT dispatch SelectAll command
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.A,
    modifiers = MOD.Control,  -- Qt: Command key = ControlModifier on macOS
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+A must pass through to text field, not dispatch SelectAll")
local found_select_all = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "SelectAll" then found_select_all = true; break end
end
assert_false(found_select_all, "SelectAll must not fire while typing in text field")

-- Test 8: Cmd+Z in text field should NOT dispatch Undo command
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Z,
    modifiers = MOD.Control,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+Z must pass through to text field for inline undo")
local found_undo_in_text = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "Undo" then found_undo_in_text = true; break end
end
assert_false(found_undo_in_text, "Undo must not fire while typing in text field")

-- Test 9: Cmd+B in text field should NOT dispatch Blade command
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.B,
    modifiers = MOD.Control,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Cmd+B must pass through to text field, not dispatch Blade")
local found_blade = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "Blade" then found_blade = true; break end
end
assert_false(found_blade, "Blade must not fire while typing in text field")

-- Test 10: focus_widget_is_text_input=0 (C++ false) must NOT bypass
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.I,
    modifiers = MOD.NoModifier,
    text = "i",
    focus_widget_is_text_input = 0,  -- C++ lua_pushboolean(false) = 0
})
assert_true(handled, "focus_widget_is_text_input=0 must not trigger text bypass")
local found_mark_from_zero = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "SetMark" then found_mark_from_zero = true; break end
end
assert_true(found_mark_from_zero, "SetMark must dispatch when focus_widget_is_text_input=0")

-- Test 11: focus_widget_is_text_input=nil (missing field) must NOT bypass
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.I,
    modifiers = MOD.NoModifier,
    text = "i",
    -- focus_widget_is_text_input omitted entirely
})
assert_true(handled, "missing focus_widget_is_text_input must not trigger text bypass")
local found_mark_from_nil = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "SetMark" then found_mark_from_nil = true; break end
end
assert_true(found_mark_from_nil, "SetMark must dispatch when focus_widget_is_text_input is nil")

-- Test 12: Arrow keys in text field must pass through (not start arrow_repeat)
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Left,
    modifiers = MOD.NoModifier,
    text = "",
    focus_widget_is_text_input = true,
})
assert_false(handled, "Left arrow must pass through to text field for cursor movement")
local found_move_in_text = false
for _, cmd in ipairs(command_manager_stub.executed_commands) do
    if cmd == "MovePlayhead" then found_move_in_text = true; break end
end
assert_false(found_move_in_text, "MovePlayhead must not fire while in text field")

-- Test 13: Escape in text field cancels timecode entry
reset_environment()
focus_manager.set_focused_panel("timeline")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Escape,
    modifiers = MOD.NoModifier,
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
    key = KEY.Escape,
    modifiers = MOD.NoModifier,
    text = "",
    focus_widget_is_text_input = false,
})
assert_false(handled, "Escape outside text field should not be consumed")
assert_equal(timeline_panel_stub.cancel_timecode_calls, 0,
    "cancel_timecode_entry must not be called outside text field")

print("✅ keyboard focus routing tests passed")
