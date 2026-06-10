#!/usr/bin/env luajit

-- Contract test: the timeline wheel-event protocol requires every Lua
-- wheel handler to return a boolean indicating whether C++ should
-- propagate the event to the parent QScrollArea. The C++ side (in
-- TimelineRenderer::wheelEvent) JVE_FAILs at runtime if a non-boolean
-- comes back. This test catches a missing/wrong return at the Lua
-- boundary so the bug is visible during make -j4 (luacheck + lua tests)
-- rather than only at runtime when a wheel event finally fires.
--
-- Domain expectation (model-owned scroll): handle_wheel(view, dx, dy,
-- mods) ALWAYS returns false — vertical scrolling goes through the
-- injected view.vertical_scroll entry point (the model write path), so
-- C++ must never forward to QWidget::wheelEvent where native
-- QScrollArea scrolling would move the view behind the model's back.
-- A vertical-dominant gesture is observable as vertical_scroll.by(dy)
-- calls, not as a true return.

require("test_env")

-- H1 (#28): command_manager captures playhead from the displayed tab's

-- cache. Tests that exercise command_manager without a real timeline

-- install a default stub (playhead=0, viewport=(0,300), fps=30/1) so

-- capture succeeds. Pre-H1 the singleton mirror provided these defaults

-- implicitly; post-H1 every test states its intent explicitly.

require('test_env').install_displayed_tab_stub()

local input = require("ui.timeline.view.timeline_view_input")

-- Build a minimal mock view that satisfies handle_wheel's contract
-- without needing a real Qt widget or sequence state.
local mock_state = {
    get_viewport_duration = function() return 1000 end,
    get_viewport_start_time = function() return 0 end,
    set_viewport_start_time = function() end,
    flush_pending_notify = function() end,
}
local vertical_scroll_dys = {}
local view = {
    state = mock_state,
    widget = "mock_widget",
    -- The panel injects this in production; vertical wheel intent must
    -- arrive here (model write path), never via Qt propagation.
    vertical_scroll = { by = function(dy) table.insert(vertical_scroll_dys, dy) end },
}

-- handle_wheel calls timeline.get_dimensions to convert pixels → frames.
-- Stub it so the function reaches the return statement.
_G.timeline = {
    get_dimensions = function() return 1000 end,
    set_pan_offset_px = function() end,
}

-- =============================================================================
-- Test 1: horizontal-dominant gesture returns false (suppress propagation)
-- =============================================================================
-- A clean horizontal sweep that crosses HORIZONTAL_COMMIT_PX before any
-- vertical intent threshold — axis lock pins horizontal_only, dy zeroed,
-- handle_wheel returns false so C++ won't let Qt scroll vertically.
local result_h = nil
for _ = 1, 5 do
    result_h = input.handle_wheel(view, 10, 1, {})
end
assert(type(result_h) == "boolean",
    "handle_wheel must return a boolean for horizontal gestures, got " .. type(result_h))
assert(result_h == false,
    "horizontal-dominant gesture must return false (vertical suppressed), got " .. tostring(result_h))
print("  PASS: horizontal-dominant gesture returns false")

-- =============================================================================
-- Test 2: pure-vertical gesture scrolls via the injected entry point,
-- still returns false (Qt must never scroll natively)
-- =============================================================================
view._scroll_axis_state = nil  -- fresh gesture state (also: a wall-clock gap
                               -- would reset it, but the simpler way is to
                               -- discard and re-create per test).
local result_v = nil
for _ = 1, 8 do
    result_v = input.handle_wheel(view, 0, 8, {})
end
assert(type(result_v) == "boolean",
    "handle_wheel must return a boolean for vertical gestures, got " .. type(result_v))
assert(result_v == false,
    "vertical gesture must return false — vertical scroll goes through the "
    .. "model write path, never Qt propagation; got " .. tostring(result_v))
assert(#vertical_scroll_dys > 0,
    "sustained-vertical gesture must reach the injected vertical_scroll entry point")
print("  PASS: sustained-vertical gesture scrolls via model path, returns false")

-- =============================================================================
-- Test 3: handle_wheel rejects non-numeric deltas (NSF input validation)
-- =============================================================================
local ok = pcall(input.handle_wheel, view, nil, 5, {})
assert(not ok, "handle_wheel must assert on nil delta_x, not silently default to 0")
ok = pcall(input.handle_wheel, view, 10, "5", {})
assert(not ok, "handle_wheel must assert on non-numeric delta_y, not coerce")
print("  PASS: handle_wheel asserts on invalid deltas")

print("\n✅ test_wheel_handler_returns_bool.lua passed")
