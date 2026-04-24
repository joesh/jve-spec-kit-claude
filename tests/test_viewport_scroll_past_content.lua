#!/usr/bin/env luajit

-- Regression: scrolling downstream past content must apply the full desired
-- delta in a single call. Previously, once viewport_end exceeded content_end,
-- each call only advanced the viewport by `buffer_frames` (10 seconds' worth
-- of frames) regardless of the caller's desired position, because the extent
-- ceiling was computed from the CURRENT viewport_start rather than the
-- desired one. This made rightward scrolling feel orders of magnitude slower
-- than leftward scrolling when zoomed out.
--
-- Domain expectation: a user who asks to scroll 5000 frames forward gets
-- 5000 frames of movement, not 240.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local data = require("ui.timeline.state.timeline_state_data")
local viewport_state = require("ui.timeline.state.viewport_state")

local function reset(opts)
    data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
    data.state.viewport_start_time = opts.start
    data.state.viewport_duration = opts.duration
    data.state.playhead_position = 0
    data.state.sequence_timecode_start_frame = 0
    data.state.clips = opts.clips or {}
end

-- =============================================================================
-- Setup: short content (100-frame clip), viewport wider than content, parked
-- at a position where viewport_end already sits past content_end.
-- =============================================================================
reset({
    start = 500,
    duration = 300,
    clips = { { id = "c1", track_id = "t1", timeline_start = 0, duration = 100 } },
})

-- =============================================================================
-- Test: large desired-forward delta applies in full (not throttled to buffer)
-- =============================================================================
viewport_state.set_viewport_start_time(5000)
assert(data.state.viewport_start_time == 5000, string.format(
    "expected viewport_start=5000 after requesting 5000, got %d (clamped to buffer?)",
    data.state.viewport_start_time))
print("  PASS: rightward scroll past content applies full delta")

-- =============================================================================
-- Test: symmetry — large leftward delta from the same far-right position also
-- applies in full, bounded only by the timeline floor.
-- =============================================================================
viewport_state.set_viewport_start_time(500)
assert(data.state.viewport_start_time == 500, string.format(
    "expected viewport_start=500 after leftward move, got %d",
    data.state.viewport_start_time))
print("  PASS: leftward scroll applies full delta")

-- =============================================================================
-- Test: floor still enforced — cannot scroll below sequence_timecode_start_frame.
-- =============================================================================
reset({
    start = 500,
    duration = 300,
    clips = { { id = "c1", track_id = "t1", timeline_start = 0, duration = 100 } },
})
data.state.sequence_timecode_start_frame = 0
viewport_state.set_viewport_start_time(-1000)
assert(data.state.viewport_start_time == 0, string.format(
    "expected viewport_start=0 (clamped to floor), got %d",
    data.state.viewport_start_time))
print("  PASS: floor clamp still enforced")

-- =============================================================================
-- Test: non-zero timecode floor enforced.
-- =============================================================================
reset({
    start = 1000,
    duration = 300,
    clips = { { id = "c1", track_id = "t1", timeline_start = 500, duration = 100 } },
})
data.state.sequence_timecode_start_frame = 500
viewport_state.set_viewport_start_time(100)
assert(data.state.viewport_start_time == 500, string.format(
    "expected viewport_start=500 (sequence tc floor), got %d",
    data.state.viewport_start_time))
print("  PASS: non-zero tc floor enforced")

-- =============================================================================
-- Test: scrolling to frame 0 from a non-zero position applies in full.
-- Guards against a Lua-truthiness trap in the extent calculation: when a
-- caller's desired target is 0 (falsy in Lua's `a or b`), earlier iterations
-- of the fix used `desired or current` and silently substituted the current
-- viewport_start — making "go to frame 0" behave like "stay where you are"
-- under some layouts.
-- =============================================================================
reset({
    start = 10000,
    duration = 300,
    clips = { { id = "c1", track_id = "t1", timeline_start = 0, duration = 100 } },
})
viewport_state.set_viewport_start_time(0)
assert(data.state.viewport_start_time == 0, string.format(
    "expected viewport_start=0 when requesting 0, got %d",
    data.state.viewport_start_time))
print("  PASS: scroll to frame 0 applies (no Lua-truthiness trap)")

-- =============================================================================
-- Test: get_timeline_extent returns a sensible positive frame count that
-- encloses the current viewport. Domain: the scrollbar uses this as its
-- thumb denominator, so 0, negative, or a value smaller than the viewport
-- would break thumb geometry.
-- =============================================================================
reset({
    start = 500,
    duration = 300,
    clips = { { id = "c1", track_id = "t1", timeline_start = 0, duration = 100 } },
})
local extent = viewport_state.get_timeline_extent()
assert(type(extent) == "number" and extent > 0,
    string.format("get_timeline_extent must return positive number, got %s", tostring(extent)))
assert(extent >= data.state.viewport_start_time + data.state.viewport_duration,
    string.format("get_timeline_extent (%d) must enclose current viewport end (%d)",
        extent, data.state.viewport_start_time + data.state.viewport_duration))
print("  PASS: get_timeline_extent returns sensible total")

-- =============================================================================
-- Test: input validation — set_viewport_start_time must reject a non-integer
-- target with an actionable assert (fail-fast, no silent coercion).
-- =============================================================================
local ok, err = pcall(viewport_state.set_viewport_start_time, 123.5)
assert(not ok, "set_viewport_start_time(123.5) must assert")
assert(tostring(err):find("integer"),
    string.format("assert message must name the violation, got: %s", tostring(err)))
print("  PASS: non-integer target rejected with actionable message")

print("✅ test_viewport_scroll_past_content.lua passed")
