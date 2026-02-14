#!/usr/bin/env luajit
-- Regression Test: Timeline Zoom commands handle integer durations without crashing

require('test_env')

-- Mock timeline_state so zoom commands find it via pcall(require)
local mock_state = {}
mock_state._duration = 10000
mock_state.get_viewport_duration = function() return mock_state._duration end
mock_state.set_viewport_duration = function(val)
    mock_state._duration = val
    print("DEBUG: set_viewport_duration called with " .. tostring(val))
end

package.loaded["ui.timeline.timeline_state"] = mock_state

local function make_cmd(params)
    return { get_all_parameters = function() return params or {} end }
end

local function make_set_last_error()
    return function(msg) error(msg) end
end

print("=== Testing TimelineZoomIn ===")
local zoom_in_mod = require("core.commands.timeline_zoom_in")
local executors = {}
zoom_in_mod.register(executors, {}, nil, make_set_last_error())

local ok, err = pcall(executors["TimelineZoomIn"], make_cmd({ project_id = "test" }))
assert(ok, "TimelineZoomIn failed: " .. tostring(err))
assert(mock_state._duration == 8000,
    "expected 8000 after 0.8x zoom, got " .. tostring(mock_state._duration))
print("✅ TimelineZoomIn succeeded")

print("=== Testing TimelineZoomOut ===")
mock_state._duration = 10000
local zoom_out_mod = require("core.commands.timeline_zoom_out")
zoom_out_mod.register(executors, {}, nil, make_set_last_error())

ok, err = pcall(executors["TimelineZoomOut"], make_cmd({ project_id = "test" }))
assert(ok, "TimelineZoomOut failed: " .. tostring(err))
assert(mock_state._duration == 12500,
    "expected 12500 after 1.25x zoom, got " .. tostring(mock_state._duration))
print("✅ TimelineZoomOut succeeded")

print("\n✅ test_zoom_rational_fix.lua passed")
