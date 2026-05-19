#!/usr/bin/env luajit
--- Two-finger trackpad scroll on the monitor mark bar scrubs the
--- playhead horizontally. Domain mapping: a horizontal wheel delta of
--- W pixels equals (W / bar_width) * viewport_duration frames of
--- playhead movement. Negative delta moves earlier.
---
--- The new playhead clamps to [start_frame, total_frames - 1] so the
--- scrub can't run off either end of the clip extent.

require("test_env")

print("=== test_monitor_mark_bar_wheel_scrubs.lua ===")

local m = require("ui.monitor_mark_bar")
assert(type(m.compute_wheel_scrub_target) == "function",
    "monitor_mark_bar.compute_wheel_scrub_target(playhead, delta_x, width, "
    .. "viewport_duration, start_frame, total_frames) missing")

-- Helper: a 1000-frame clip, 200 px wide bar, viewport spans the whole clip.
local W, VD, SF, TF = 200, 1000, 0, 1000

-- ── Forward scroll: +200 px on a 1000-frame viewport = +1000 frames ──
local p = m.compute_wheel_scrub_target(100, 200, W, VD, SF, TF)
assert(p == TF - 1, string.format(
    "forward scroll past end must clamp to total_frames-1 (%d); got %d",
    TF - 1, p))
print("  ✓ forward scroll clamps at end")

-- ── Modest forward scroll: +20 px = +100 frames ──
p = m.compute_wheel_scrub_target(100, 20, W, VD, SF, TF)
assert(p == 200, string.format(
    "forward 20 px on a 200px bar with 1000-frame viewport = +100 frames "
    .. "→ 100+100=200; got %d", p))
print("  ✓ forward scroll moves playhead by (delta/width)*duration frames")

-- ── Backward scroll: -40 px = -200 frames ──
p = m.compute_wheel_scrub_target(500, -40, W, VD, SF, TF)
assert(p == 300, string.format("backward 40 px = -200 frames → 300; got %d", p))
print("  ✓ backward scroll moves playhead backwards")

-- ── Backward past start clamps to start_frame ──
p = m.compute_wheel_scrub_target(10, -500, W, VD, SF, TF)
assert(p == SF, string.format(
    "backward scroll past start must clamp to start_frame (%d); got %d",
    SF, p))
print("  ✓ backward scroll clamps at start")

-- ── Zero delta = no movement ──
p = m.compute_wheel_scrub_target(100, 0, W, VD, SF, TF)
assert(p == 100, "zero delta must leave playhead untouched")
print("  ✓ zero delta is a no-op")

-- ── Contract: registered wheel handler returns boolean ──────────────────────
-- C++ TimelineRenderer::wheelEvent asserts the Lua handler returns bool.
-- Build the bar end-to-end and call the registered handler with a wheel
-- event to pin the contract: every wheel branch (no-clip, zero-width,
-- zero-delta, real delta) returns true.
print("-- wheel handler returns bool contract --")

local seek_log = {}
local has_clip_flag = true
local fake_state = {
    playhead = 100, viewport_start = 0, viewport_duration = 1000,
    start_frame = 0, total_frames = 1000,
}
local stored_handler
-- Stub every timeline.* helper with a no-op; mark_bar.render calls a
-- bunch of draw primitives we don't care about here. Override only the
-- handlers we DO care about.
_G.timeline = setmetatable({
    set_mouse_event_handler = function(_, name) stored_handler = name end,
    get_dimensions          = function() return W, m.BAR_HEIGHT end,
}, { __index = function() return function() end end })

m.create({_id=1}, {
    state_provider = fake_state,
    has_clip       = function() return has_clip_flag end,
    get_mark_in    = function() return nil end,
    get_mark_out   = function() return nil end,
    on_seek        = function(f) seek_log[#seek_log + 1] = f end,
    on_listener    = function() end,
})
assert(stored_handler and _G[stored_handler],
    "fixture: set_mouse_event_handler should have registered a handler")
local handler = _G[stored_handler]

local r
r = handler({type="wheel", delta_x=0, delta_y=0})
assert(r == true, string.format("zero-delta wheel must return true; got %s", tostring(r)))

r = handler({type="wheel", delta_x=20, delta_y=0})
assert(r == true, string.format("real-delta wheel must return true; got %s", tostring(r)))

has_clip_flag = false
r = handler({type="wheel", delta_x=20, delta_y=0})
assert(r == true, string.format("no-clip wheel must return true; got %s", tostring(r)))
print("  ✓ every wheel branch returns true (C++ wheelEvent contract)")

print("\n✅ test_monitor_mark_bar_wheel_scrubs.lua passed")
