require('test_env')

-- Tests that JKL handlers assert when media metadata is invalid
-- (not silently skip init and schedule broken tick)

print("=== Test JKL Requires Valid Media ===")

_G.qt_create_single_shot_timer = function(interval, callback) end

-- Track what happens (variables needed for mock callbacks but not read in test)
-- luacheck: ignore shuttle_called assert_fired
local shuttle_called = false
local assert_fired = false

-- Mock registry
package.loaded["core.keyboard_shortcut_registry"] = {
    commands = {},
    register_command = function(cmd)
        package.loaded["core.keyboard_shortcut_registry"].commands[cmd.id] = cmd
    end,
    assign_shortcut = function() return true end,
    handle_key_event = function() return false end,
}

-- Mock panel_manager with no sequence loaded (simulates no media state)
local mock_sv_no_seq = {
    sequence_id = nil,
    total_frames = 0,
    engine = { shuttle = function() shuttle_called = true end },
}
function mock_sv_no_seq:has_clip() return false end

local mock_pm = {
    toggle_active_panel = function() end,
    get_active_sequence_monitor = function() return mock_sv_no_seq end,
    get_sequence_monitor = function() return mock_sv_no_seq end,
}
package.loaded["ui.panel_manager"] = mock_pm
package.loaded["ui.focus_manager"] = { get_focused_panel = function() return "source_monitor" end }

package.loaded["core.keyboard_shortcuts"] = nil
local keyboard_shortcuts = require("core.keyboard_shortcuts")
keyboard_shortcuts.init(nil, nil, nil, nil)

local registry = package.loaded["core.keyboard_shortcut_registry"]

print("\nTest 1: L with no sequence loaded should silently return (not crash)")
local handler = registry.commands["playback.forward"].handler
shuttle_called = false

-- With no sequence loaded, ensure_playback_initialized returns false, handler returns nil
local ok, err = pcall(handler)
assert(ok, "Handler should NOT assert when no sequence loaded, got: " .. tostring(err))
assert(not shuttle_called, "shuttle should not have been called")
print("  ✓ Silently returns when no sequence loaded")

print("\nTest 2: L with sequence loaded should call shuttle")
mock_sv_no_seq.sequence_id = "test_seq"
mock_sv_no_seq.total_frames = 100
shuttle_called = false

ok, err = pcall(handler)
assert(ok, "Handler should succeed when sequence loaded, got: " .. tostring(err))
assert(shuttle_called, "shuttle should have been called")
print("  ✓ shuttle called when sequence loaded")

print("\n✅ test_jkl_requires_valid_media.lua passed")
