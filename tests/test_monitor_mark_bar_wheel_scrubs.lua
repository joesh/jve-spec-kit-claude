#!/usr/bin/env luajit
--- Wheel/trackpad gestures on the monitor mark bar dispatch through
--- the command system so the gesture→action mapping is rebindable
--- (gesture editor analog of the keyboard editor, planned).
---
--- Mappings (default — overridable when the gesture editor lands):
---   plain wheel/trackpad horizontal scroll → ScrubMonitorPlayhead
---   Opt + wheel/trackpad horizontal scroll → PanMonitorMarkBar
---
--- Each command receives `monitor_view_id` (which monitor's mark bar
--- the gesture happened on) and `delta_frames` (pixel delta translated
--- to a frame count via the bar's pixel/frame scale).

require("test_env")

print("=== test_monitor_mark_bar_wheel_scrubs.lua ===")

local m = require("ui.monitor_mark_bar")

-- ── Pixel-to-frame conversion helper ─────────────────────────────────────────
-- The wheel handler converts pixel deltas to frame deltas using the bar's
-- pixel/frame scale; the commands themselves consume frame deltas. Keeping
-- the conversion as a pure helper keeps the dispatch math testable without
-- a Qt harness.
assert(type(m.compute_wheel_frame_delta) == "function",
    "monitor_mark_bar.compute_wheel_frame_delta(delta_x, width, viewport_duration) missing")

local W, VD = 200, 1000

assert(m.compute_wheel_frame_delta(0,   W, VD) == 0,   "zero pixel delta → zero frames")
assert(m.compute_wheel_frame_delta(20,  W, VD) == 100, "+20 px / 200 px-wide bar / 1000-frame vp = +100 frames")
assert(m.compute_wheel_frame_delta(-40, W, VD) == -200, "negative pixel delta → negative frame delta")
print("  ✓ compute_wheel_frame_delta math")

-- ── Wheel dispatch: plain wheel → scrub command, Opt → pan command ───────────
-- Stub command_manager.execute to capture dispatches. Replace it on the
-- already-loaded module table so the wheel handler's require() returns
-- this stub.
local dispatched = {}
package.loaded["core.command_manager"] = {
    execute = function(name, args)
        table.insert(dispatched, { name = name, args = args })
        return true
    end,
}

local fake_state = {
    playhead = 100, viewport_start = 0, viewport_duration = VD,
    start_frame = 0, total_frames = 1000,
}
local stored_handler
_G.timeline = setmetatable({
    set_mouse_event_handler = function(_, name) stored_handler = name end,
    get_dimensions          = function() return W, m.BAR_HEIGHT end,
}, { __index = function() return function() end end })

m.create({_id=1}, {
    state_provider   = fake_state,
    has_clip         = function() return true end,
    get_mark_in      = function() return nil end,
    get_mark_out     = function() return nil end,
    on_seek          = function() end,
    on_listener      = function() end,
    monitor_view_id  = "test_monitor",
})
local handler = _G[stored_handler]
assert(handler, "fixture: wheel handler must be registered")

-- Plain wheel (no modifiers) → ScrubMonitorPlayhead
dispatched = {}
local r = handler({type="wheel", delta_x=20, delta_y=0, modifiers={}})
assert(r == true, string.format("wheel handler must return true; got %s", tostring(r)))
assert(#dispatched == 1, string.format(
    "plain wheel must dispatch exactly one command; got %d", #dispatched))
assert(dispatched[1].name == "ScrubMonitorPlayhead", string.format(
    "plain wheel must dispatch ScrubMonitorPlayhead; got %s",
    tostring(dispatched[1].name)))
assert(dispatched[1].args.monitor_view_id == "test_monitor", string.format(
    "scrub command must carry monitor_view_id; got %s",
    tostring(dispatched[1].args.monitor_view_id)))
assert(dispatched[1].args.delta_frames == 100, string.format(
    "scrub command must carry delta_frames=100; got %s",
    tostring(dispatched[1].args.delta_frames)))
print("  ✓ plain wheel dispatches ScrubMonitorPlayhead with delta_frames")

-- Opt+wheel → PanMonitorMarkBar
dispatched = {}
r = handler({type="wheel", delta_x=20, delta_y=0, modifiers={alt=true}})
assert(r == true, string.format("Opt+wheel handler must return true; got %s", tostring(r)))
assert(#dispatched == 1, "Opt+wheel must dispatch exactly one command")
assert(dispatched[1].name == "PanMonitorMarkBar", string.format(
    "Opt+wheel must dispatch PanMonitorMarkBar; got %s",
    tostring(dispatched[1].name)))
assert(dispatched[1].args.monitor_view_id == "test_monitor",
    "pan command must carry monitor_view_id")
assert(dispatched[1].args.delta_frames == 100, string.format(
    "pan command must carry delta_frames=100; got %s",
    tostring(dispatched[1].args.delta_frames)))
print("  ✓ Opt+wheel dispatches PanMonitorMarkBar with delta_frames")

-- Zero delta after no-axis filtering → no dispatch (still returns true)
dispatched = {}
r = handler({type="wheel", delta_x=0, delta_y=0, modifiers={}})
assert(r == true, "zero-delta wheel must return true")
assert(#dispatched == 0, string.format(
    "zero-delta wheel must NOT dispatch (saves a no-op command round-trip); "
    .. "got %d dispatches", #dispatched))
print("  ✓ zero-delta wheel is a no-op (still returns true)")

-- No-clip state → no dispatch (still returns true)
dispatched = {}
local no_clip_handler_state = true
package.loaded["ui.monitor_mark_bar"] = nil  -- isolate next create
local m2 = require("ui.monitor_mark_bar")
_G.timeline = setmetatable({
    set_mouse_event_handler = function(_, name) stored_handler = name end,
    get_dimensions          = function() return W, m2.BAR_HEIGHT end,
}, { __index = function() return function() end end })
m2.create({_id=2}, {
    state_provider   = fake_state,
    has_clip         = function() return false end,
    get_mark_in      = function() return nil end,
    get_mark_out     = function() return nil end,
    on_seek          = function() end,
    on_listener      = function() end,
    monitor_view_id  = "test_monitor",
})
local h2 = _G[stored_handler]
dispatched = {}
r = h2({type="wheel", delta_x=20, delta_y=0, modifiers={}})
assert(r == true, "no-clip wheel must return true")
assert(#dispatched == 0, "no-clip wheel must NOT dispatch")
print("  ✓ no-clip wheel is a no-op (still returns true)")
_ = no_clip_handler_state

print("\n✅ test_monitor_mark_bar_wheel_scrubs.lua passed")
