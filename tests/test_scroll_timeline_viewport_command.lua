#!/usr/bin/env luajit
--- ScrollTimelineViewport — rebindable gesture command that shifts the
--- displayed timeline's horizontal viewport by an integer frame delta.
---
--- Default binding: plain wheel/trackpad horizontal scroll on the
--- ruler or the timeline view. The handlers do the pixel→frame
--- conversion (including any sub-frame fractional-accumulator math
--- that lives at the UI layer); this command adds delta_frames to
--- viewport_start_time and lets timeline_state's clamping do its job.

require("test_env")

print("=== test_scroll_timeline_viewport_command.lua ===")

-- Patch just the two methods the command touches on the real
-- timeline_state. Replacing the module wholesale broke
-- command_manager's auto-injection helpers (get_selected_clips,
-- frame_rate, etc) which other layers rely on; a surgical spy keeps
-- those intact.
local timeline_state = require("ui.timeline.timeline_state")
local current_start = 500
local set_calls = {}
timeline_state.get_viewport_start_time = function() return current_start end
timeline_state.set_viewport_start_time = function(new_start)
    table.insert(set_calls, new_start)
    current_start = new_start
end

local command_manager = require("core.command_manager")

-- ── Positive delta shifts viewport forward ────────────────────────────────
assert(command_manager.execute("ScrollTimelineViewport", { delta_frames = 50 }),
    "ScrollTimelineViewport must succeed for positive delta")
assert(#set_calls == 1, string.format(
    "command must call set_viewport_start_time exactly once; got %d", #set_calls))
assert(set_calls[1] == 550, string.format(
    "positive delta: viewport_start 500 + delta 50 = 550; got %s",
    tostring(set_calls[1])))
print("  ✓ positive delta moves viewport forward")

-- ── Negative delta shifts viewport backward ───────────────────────────────
set_calls = {}
current_start = 500
assert(command_manager.execute("ScrollTimelineViewport", { delta_frames = -120 }),
    "ScrollTimelineViewport must succeed for negative delta")
assert(set_calls[1] == 380, string.format(
    "negative delta: viewport_start 500 - delta 120 = 380; got %s",
    tostring(set_calls[1])))
print("  ✓ negative delta moves viewport backward")

-- (Zero-delta and fractional-pixel filtering live at the wheel-handler
-- layer — the handler's job is to deliver whole-frame, non-zero deltas
-- to the command. Tested at the call site, not here.)

print("\n✅ test_scroll_timeline_viewport_command.lua passed")
