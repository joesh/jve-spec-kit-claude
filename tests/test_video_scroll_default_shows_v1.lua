#!/usr/bin/env luajit
--- New / freshly-created sequences MUST default the video timeline to
--- "V1 visible at the bottom of the viewport," NOT "V_n at the top."
--- Video tracks are laid out V_n…V1 top-to-bottom in the scroll
--- content widget (V1 anchored at the BOTTOM); a fresh scroll offset
--- of 0 leaves the viewport at the top showing V_n.
---
--- Schema carries an "uninitialized" sentinel; the renderer translates
--- the sentinel to a "scroll past max" value that Qt clamps to the
--- actual viewport-bottom — which surfaces V1.

require("test_env")

local stub_qt = setmetatable({},
    { __index = function() return setmetatable({}, { __index = function() return function() end end }) end })
package.loaded["core.qt_constants"] = stub_qt
_G.qt_constants = stub_qt
_G.qt_set_widget_cursor       = function() end
_G.qt_set_widget_drag_handler = function() end
_G.qt_set_layout_stretch_factor = function() end
package.loaded["core.logger"] = {
    for_area = function() return {
        event = function() end, detail = function() end,
        warn = function() end, error = function() end,
    } end,
}

print("=== test_video_scroll_default_shows_v1.lua ===")

local panel = require("ui.timeline.timeline_panel")
local m = panel.metrics

assert(m.UNINITIALIZED_SCROLL_OFFSET == -1, string.format(
    "panel.metrics.UNINITIALIZED_SCROLL_OFFSET sentinel must be -1; got %s",
    tostring(m.UNINITIALIZED_SCROLL_OFFSET)))
print("  ✓ sentinel constant exposed")

assert(type(m.compute_initial_scroll_target) == "function",
    "panel.metrics.compute_initial_scroll_target(offset) missing")

-- Sentinel → very large number (Qt clamps to actual viewport-bottom max).
local big = m.compute_initial_scroll_target(m.UNINITIALIZED_SCROLL_OFFSET)
assert(type(big) == "number" and big > 1000000, string.format(
    "compute_initial_scroll_target(sentinel) must return a value larger than "
    .. "any plausible content height so Qt clamps to max (V1 visible); got %s",
    tostring(big)))
print("  ✓ sentinel → scroll past max (V1 visible)")

-- Real (non-sentinel) values pass through unchanged: user-saved scroll wins.
assert(m.compute_initial_scroll_target(0) == 0,
    "user-saved offset 0 (user scrolled to top) must pass through unchanged")
assert(m.compute_initial_scroll_target(500) == 500,
    "user-saved offset 500 must pass through unchanged")
print("  ✓ user-saved offsets pass through unchanged")

print("\n✅ test_video_scroll_default_shows_v1.lua passed")
