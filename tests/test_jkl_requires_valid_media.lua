require('test_env')

-- Tests that JKL handlers assert when media metadata is invalid
-- (not silently skip init and schedule broken tick)

print("=== Test JKL Requires Valid Media ===")

_G.qt_create_single_shot_timer = function(interval, callback) end

-- Track what happens
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

package.loaded["ui.panel_manager"] = { toggle_active_panel = function() end }
package.loaded["ui.focus_manager"] = { get_focused_panel = function() return "viewer" end }

-- Mock playback_controller - track if shuttle is called without proper init
local mock_pc = {
    total_frames = 0,  -- Not initialized
    frame = 0,
    init = function() end,
    set_source = function(total, fps)
        mock_pc.total_frames = total
    end,
    stop = function() end,
    shuttle = function(dir)
        shuttle_called = true
        -- In real code, this would schedule _tick which fails
    end,
    slow_play = function(dir)
        shuttle_called = true
    end,
}
package.loaded["ui.playback_controller"] = mock_pc

-- Mock viewer_panel with INVALID metadata (fps=0)
package.loaded["ui.viewer_panel"] = {
    has_media = function() return true end,  -- Claims to have media
    get_total_frames = function() return 100 end,
    get_fps = function() return 0 end,  -- BUG: invalid fps
    get_current_frame = function() return 0 end,
}

package.loaded["core.keyboard_shortcuts"] = nil
local keyboard_shortcuts = require("core.keyboard_shortcuts")
keyboard_shortcuts.init(nil, nil, nil, nil)

local registry = package.loaded["core.keyboard_shortcut_registry"]

print("\nTest 1: L with has_media=true but fps=0 should assert")
local handler = registry.commands["playback.forward"].handler

-- Should assert, not silently fail
local ok, err = pcall(handler)
assert(not ok, "Handler should have asserted on invalid fps, but it didn't fail")
assert(err:match("fps") or err:match("FPS") or err:match("frame rate"),
    "Assert message should mention fps/frame rate, got: " .. tostring(err))
print("  ✓ Asserted on invalid fps: " .. tostring(err):sub(1,60))

-- Reset
shuttle_called = false
mock_pc.total_frames = 0

print("\nTest 2: L with has_media=true but total_frames=0 should assert")
package.loaded["ui.viewer_panel"].get_fps = function() return 24 end
package.loaded["ui.viewer_panel"].get_total_frames = function() return 0 end

ok, err = pcall(handler)
assert(not ok, "Handler should have asserted on zero total_frames")
assert(err:match("frame") or err:match("total"),
    "Assert message should mention frames, got: " .. tostring(err))
print("  ✓ Asserted on zero total_frames: " .. tostring(err):sub(1,60))

print("\n✅ test_jkl_requires_valid_media.lua passed")
