#!/usr/bin/env luajit
-- Regression: Cmd/Ctrl+B (Blade/Split) should dispatch Blade command via TOML keybindings.
-- Uses LITERAL Qt key codes to catch wrong-constant bugs.

require("test_env")

local keyboard_shortcuts = require("core.keyboard_shortcuts")
local timeline_state = require("ui.timeline.timeline_state")
local data = require("ui.timeline.state.timeline_state_data")

-- ── Literal Qt key codes ──
local QT_KEY_B = 66
local QT_MOD_CONTROL = 0x04000000  -- Cmd on macOS

-- Focus panel needs to be "timeline" for the shortcut to be active.
local focus_manager = require("ui.focus_manager")
focus_manager.get_focused_panel = function() return "timeline" end

-- Prepare timeline state
timeline_state.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.project_id = "test_project"
data.state.sequence_id = "timeline_seq"
local clip = {
    id = "clip_under_playhead",
    track_id = "v1",
    name = "Clip 1",
    timeline_start = 0,
    duration = 48,
    source_in = 0,
    source_out = 48,
    enabled = true,
}
data.state.clips = { clip }
data.state.selected_clips = { clip }
timeline_state.set_playhead_position(10)

-- Stub command manager — dispatch test only (verify routing, not execution)
local captured_commands = {}
local mock_command_manager = {
    execute_interactive = function(command_name, params)
        captured_commands[#captured_commands + 1] = {
            name = command_name,
            params = params or {},
        }
        return { success = true }
    end,
    get_executor = function(command_name)
        if command_name == "Blade" then return function() end end
        return nil
    end,
    peek_command_event_origin = function() return nil end,
    begin_command_event = function() end,
    end_command_event = function() end,
}

local mock_project_browser = { add_selected_to_timeline = function() end }
local mock_timeline_panel = { is_dragging = function() return false end }
keyboard_shortcuts.init(mock_command_manager, mock_project_browser, mock_timeline_panel)

local event = {
    key = QT_KEY_B,
    modifiers = QT_MOD_CONTROL,
    text = "b",
    focus_widget_is_text_input = 0,
}

-- After QShortcut migration, Cmd+B is NOT handled by the Lua residual handler.
-- QShortcut dispatches Blade directly. The Lua handler returns false.
local ok, err = pcall(function()
    return keyboard_shortcuts.handle_key(event)
end)

assert(ok, "keyboard_shortcuts.handle_key errored: " .. tostring(err))
assert(#captured_commands == 0,
    "Blade must not dispatch via residual handler (QShortcut handles it)")

-- Verify Cmd+B binding exists in TOML registry for QShortcut creation
local registry = require("core.keyboard_shortcut_registry")
local parsed = registry.parse_shortcut("Cmd+B")
local combo_key = string.format("%d_%d", parsed.key, parsed.modifiers)
local bindings = registry.keybindings[combo_key]
assert(bindings and #bindings > 0, "Cmd+B must exist in TOML registry")
assert(bindings[1].command_name == "Blade",
    "Cmd+B TOML binding must be Blade, got: " .. tostring(bindings[1].command_name))

print("✅ Cmd/Ctrl+B is registered in TOML for QShortcut dispatch")
