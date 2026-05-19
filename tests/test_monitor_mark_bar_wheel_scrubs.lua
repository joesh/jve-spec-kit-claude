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

print("\n✅ test_monitor_mark_bar_wheel_scrubs.lua passed")
