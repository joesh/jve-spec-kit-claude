#!/usr/bin/env luajit
-- Regression Test: Timeline Zoom Rational Fix
-- Verifies that TimelineZoomIn handles Rational durations without crashing

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local Rational = require('core.rational')
local keyboard_shortcuts = require('core.keyboard_shortcuts')

-- Mock timeline_state
local mock_state = {}
mock_state._duration = Rational.new(10000, 30, 1) -- 10s @ 30fps
mock_state.get_viewport_duration = function() return mock_state._duration end
mock_state.set_viewport_duration = function(val) 
    mock_state._duration = val
    print("DEBUG: set_viewport_duration called with " .. tostring(val))
end
mock_state.get_viewport_start_time = function() return Rational.new(0, 30, 1) end
mock_state.set_viewport_start_time = function() end
mock_state.get_playhead_position = function() return Rational.new(0, 30, 1) end

-- Inject mock state
keyboard_shortcuts.init(mock_state, nil, nil, nil)

print("=== Testing TimelineZoomIn ===")
local ok, err = pcall(function()
    keyboard_shortcuts.handle_command("TimelineZoomIn")
end)

if ok then
    print("✅ TimelineZoomIn succeeded")
else
    print("❌ TimelineZoomIn failed: " .. tostring(err))
    os.exit(1)
end

print("=== Testing TimelineZoomOut ===")
ok, err = pcall(function()
    keyboard_shortcuts.handle_command("TimelineZoomOut")
end)

if ok then
    print("✅ TimelineZoomOut succeeded")
else
    print("❌ TimelineZoomOut failed: " .. tostring(err))
    os.exit(1)
end

os.exit(0)
