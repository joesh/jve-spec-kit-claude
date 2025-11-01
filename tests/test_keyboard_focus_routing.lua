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
local timeline_marks = { in_calls = 0, out_calls = 0, last_in = nil, last_out = nil }

function timeline_state.get_sequence_frame_rate()
    return 24
end

function timeline_state.get_playhead_time()
    return timeline_state.playhead or 0
end

function timeline_state.set_playhead_time(value)
    timeline_state.playhead = value
    table.insert(timeline_moves, value)
end

function timeline_state.get_mark_in()
    return timeline_marks.last_in
end

function timeline_state.get_mark_out()
    return timeline_marks.last_out
end

function timeline_state.set_mark_in(value)
    timeline_marks.in_calls = timeline_marks.in_calls + 1
    timeline_marks.last_in = value
end

function timeline_state.set_mark_out(value)
    timeline_marks.out_calls = timeline_marks.out_calls + 1
    timeline_marks.last_out = value
end

function timeline_state.clear_marks()
    timeline_marks.cleared = true
end

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

function timeline_state.set_viewport_duration()
end

function timeline_state.set_viewport_start_time()
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

local timeline_panel_stub = {
    is_dragging = function()
        return false
    end
}

local function reset_environment()
    selection_hub._reset_for_tests()
    command_manager_stub.undo_calls = 0
    command_manager_stub.redo_calls = 0
    command_manager_stub.current_sequence_number = 0
    command_manager_stub.executed_commands = {}
    timeline_state.playhead = 100
    timeline_moves = {}
    timeline_marks = { in_calls = 0, out_calls = 0, last_in = nil, last_out = nil }
    focus_manager.set_focused_panel(nil)
    keyboard_shortcuts.init(timeline_state, command_manager_stub, nil, timeline_panel_stub)
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
assert_true(#timeline_moves == 1, "Playhead should move when timeline handles arrow keys")
assert_true(timeline_state.playhead > 100, "Playhead should advance on right arrow")

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
assert_equal(timeline_marks.in_calls, 0, "Timeline mark-in should not update while typing")

-- Test 4: Undo is still handled as a global shortcut
reset_environment()
focus_manager.set_focused_panel("inspector")
handled = keyboard_shortcuts.handle_key({
    key = KEY.Z,
    modifiers = MOD.Meta,
    text = "",
    focus_widget_is_text_input = false,
})
assert_true(handled, "Cmd/Ctrl+Z should be treated as a global command")
assert_equal(command_manager_stub.undo_calls, 1, "Global undo should be invoked exactly once")

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

print("✅ keyboard focus routing tests passed")
