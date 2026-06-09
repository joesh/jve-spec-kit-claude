#!/usr/bin/env luajit
--- ScrubMonitorPlayhead + PanMonitorMarkBar — rebindable gesture
--- commands that the mark bar's wheel handler dispatches.
---
--- Both commands take { monitor_view_id, delta_frames } and route to
--- the registered SequenceMonitor (panel_manager). Clamping is the
--- command's job; the wheel handler does pure pixel→frame conversion.

require("test_env")

-- H1 (#28): command_manager captures playhead from the displayed tab's

-- cache. Tests that exercise command_manager without a real timeline

-- install a default stub (playhead=0, viewport=(0,300), fps=30/1) so

-- capture succeeds. Pre-H1 the singleton mirror provided these defaults

-- implicitly; post-H1 every test states its intent explicitly.

require('test_env').install_displayed_tab_stub()

print("=== test_scrub_and_pan_monitor_commands.lua ===")

-- Mock SequenceMonitor: records every method call so we can assert
-- the command targeted the right one with the right values.
local function make_mock_monitor(opts)
    local m = {
        view_id           = opts.view_id,
        playhead          = opts.playhead,
        viewport_start    = opts.viewport_start,
        viewport_duration = opts.viewport_duration,
        start_frame       = opts.start_frame,
        total_frames      = opts.total_frames,
        seek_log          = {},
        viewport_log      = {},
    }
    function m:seek_to_frame(frame)
        table.insert(self.seek_log, frame)
        self.playhead = frame
    end
    function m:set_viewport(start, duration)
        table.insert(self.viewport_log, { start = start, duration = duration })
        self.viewport_start    = start
        self.viewport_duration = duration
    end
    return m
end

-- Stub panel_manager.get_sequence_monitor BEFORE requiring the commands.
local monitors = {}
package.loaded["ui.panel_manager"] = {
    get_sequence_monitor = function(view_id)
        assert(monitors[view_id], string.format(
            "test stub: no mock monitor registered for view_id=%s", view_id))
        return monitors[view_id]
    end,
}

local command_manager = require("core.command_manager")
-- Auto-load happens on first execute() via command_registry's module-path
-- inference; no bulk register needed.

-- ── ScrubMonitorPlayhead: delta added to playhead, clamped to extent ─────────
local m1 = make_mock_monitor({
    view_id = "m1", playhead = 200, viewport_start = 0, viewport_duration = 500,
    start_frame = 0, total_frames = 1000,
})
monitors.m1 = m1

assert(command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "m1", delta_frames = 50,
}), "ScrubMonitorPlayhead must succeed")
assert(#m1.seek_log == 1 and m1.seek_log[1] == 250, string.format(
    "ScrubMonitorPlayhead: playhead 200 + delta 50 = 250; got %s",
    tostring(m1.seek_log[1])))
print("  ✓ scrub adds delta_frames to playhead")

-- Clamp at end: large positive delta caps at total_frames - 1.
m1.seek_log = {}
m1.playhead = 950
assert(command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "m1", delta_frames = 500,
}), "ScrubMonitorPlayhead must succeed at clamp")
assert(m1.seek_log[1] == 999, string.format(
    "ScrubMonitorPlayhead: clamp at total_frames-1 (999); got %s",
    tostring(m1.seek_log[1])))
print("  ✓ scrub clamps at total_frames-1")

-- Clamp at start: large negative delta caps at start_frame.
m1.seek_log = {}
m1.playhead = 10
assert(command_manager.execute("ScrubMonitorPlayhead", {
    monitor_view_id = "m1", delta_frames = -500,
}), "ScrubMonitorPlayhead must succeed at clamp")
assert(m1.seek_log[1] == 0, string.format(
    "ScrubMonitorPlayhead: clamp at start_frame (0); got %s",
    tostring(m1.seek_log[1])))
print("  ✓ scrub clamps at start_frame")

-- ── PanMonitorMarkBar: delta added to viewport_start, viewport_duration kept ─
local m2 = make_mock_monitor({
    view_id = "m2", playhead = 0, viewport_start = 200, viewport_duration = 300,
    start_frame = 0, total_frames = 1000,
})
monitors.m2 = m2

assert(command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "m2", delta_frames = 100,
}), "PanMonitorMarkBar must succeed")
assert(#m2.viewport_log == 1, "pan must call set_viewport exactly once")
assert(m2.viewport_log[1].start == 300, string.format(
    "PanMonitorMarkBar: viewport_start 200 + delta 100 = 300; got %s",
    tostring(m2.viewport_log[1].start)))
assert(m2.viewport_log[1].duration == 300,
    "PanMonitorMarkBar: viewport_duration must be preserved")
print("  ✓ pan adds delta_frames to viewport_start, preserves duration")

-- Clamp pan at end: viewport_start + viewport_duration cannot exceed total_frames.
m2.viewport_log = {}
m2.viewport_start = 600  -- 600 + 300 = 900; max_start would be 700
assert(command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "m2", delta_frames = 500,
}), "PanMonitorMarkBar must succeed at clamp")
assert(m2.viewport_log[1].start == 700, string.format(
    "PanMonitorMarkBar: clamp at total_frames - viewport_duration (700); got %s",
    tostring(m2.viewport_log[1].start)))
print("  ✓ pan clamps so viewport stays within [start_frame, total_frames]")

-- Clamp pan at start.
m2.viewport_log = {}
m2.viewport_start = 100
assert(command_manager.execute("PanMonitorMarkBar", {
    monitor_view_id = "m2", delta_frames = -500,
}), "PanMonitorMarkBar must succeed at clamp")
assert(m2.viewport_log[1].start == 0, string.format(
    "PanMonitorMarkBar: clamp at start_frame (0); got %s",
    tostring(m2.viewport_log[1].start)))
print("  ✓ pan clamps at start_frame")

print("\n✅ test_scrub_and_pan_monitor_commands.lua passed")
