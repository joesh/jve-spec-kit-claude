require('test_env')

-- Test: Single-Source Playhead
-- Verify that get_position() reads from timeline_state in timeline mode,
-- not from a stale cached M._position value.
-- This catches the bug where commands that update timeline_state.playhead_position
-- get overwritten by the next playback tick reading stale M._position.

-- Mock qt_constants
local mock_qt_constants = {
    EMP = {
        ASSET_OPEN = function() return nil, { msg = "mock" } end,
        ASSET_INFO = function() return nil end,
        ASSET_CLOSE = function() end,
        READER_CREATE = function() return nil, { msg = "mock" } end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil, { msg = "mock" } end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        SET_DECODE_MODE = function() end,
    },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    is_loaded = function() return false end,
    set_playhead = function() end,
    activate = function() end,
}

-- Mock viewer_panel
local mock_viewer = {
    show_frame = function() end,
    show_frame_at_time = function() end,
    show_gap = function() end,
    has_media = function() return true end,
}

-- Mock timer
_G.qt_create_single_shot_timer = function(interval, callback)
    -- Don't execute timers automatically
end

local Rational = require("core.rational")

-- Create a mock timeline_state with playhead tracking
local mock_timeline_state = {
    _playhead = Rational.new(0, 24, 1),
    _listeners = {},
}

function mock_timeline_state.get_playhead_position()
    return mock_timeline_state._playhead
end

function mock_timeline_state.set_playhead_position(rat)
    mock_timeline_state._playhead = rat
    for _, fn in ipairs(mock_timeline_state._listeners) do
        fn()
    end
end

function mock_timeline_state.add_listener(fn)
    table.insert(mock_timeline_state._listeners, fn)
    return #mock_timeline_state._listeners
end

function mock_timeline_state.get_sequence_frame_rate()
    return { fps_numerator = 24, fps_denominator = 1 }
end

-- Preload mock timeline_state so playback_controller finds it
package.loaded["ui.timeline.timeline_state"] = mock_timeline_state

-- Load playback controller
local pc = require("core.playback.playback_controller")
pc.init(mock_viewer)

print("=== Test Single-Source Playhead ===")

print("\nTest 1: get_position/set_position exist as functions")
assert(type(pc.get_position) == "function", "get_position must be a function")
assert(type(pc.set_position) == "function", "set_position must be a function")
print("  ✓ Accessors exist")

print("\nTest 2: In source mode, get_position returns local _position")
pc.set_source(100, 24, 1)
assert(pc.timeline_mode == false, "Should be in source mode")
pc.set_position(42)
assert(pc.get_position() == 42, "get_position should return 42 in source mode, got: " .. pc.get_position())
print("  ✓ Source mode: get_position returns local value")

print("\nTest 3: In timeline mode, get_position reads from timeline_state")
pc.set_timeline_mode(true, "test_seq", { fps_num = 24, fps_den = 1, total_frames = 1000 })
-- Set timeline_state playhead to frame 50
mock_timeline_state.set_playhead_position(Rational.new(50, 24, 1))
local pos = pc.get_position()
assert(pos == 50, "get_position should read frame 50 from timeline_state, got: " .. tostring(pos))
print("  ✓ Timeline mode: get_position reads from timeline_state")

print("\nTest 4: External playhead change is visible via get_position")
-- Simulate a command changing the playhead (e.g. GoToStart)
mock_timeline_state.set_playhead_position(Rational.new(0, 24, 1))
pos = pc.get_position()
assert(pos == 0, "get_position should reflect external change to frame 0, got: " .. tostring(pos))
print("  ✓ External playhead change reflected immediately")

print("\nTest 5: set_position in timeline mode writes to timeline_state")
pc.set_position(75)
local playhead = mock_timeline_state.get_playhead_position()
assert(playhead.frames == 75, "timeline_state playhead should be at frame 75, got: " .. tostring(playhead.frames))
print("  ✓ set_position writes through to timeline_state")

print("\nTest 6: Simulated playback tick uses get_position, not stale cache")
-- Set playhead to frame 100 via timeline_state (simulating a command)
mock_timeline_state.set_playhead_position(Rational.new(100, 24, 1))
-- Verify get_position sees it (would have been stale before this refactor)
pos = pc.get_position()
assert(pos == 100, "After external set to 100, get_position should return 100, got: " .. tostring(pos))
print("  ✓ No stale cache: get_position always reads timeline_state in timeline mode")

-- Clean up
pc.set_timeline_mode(false)
pc.stop()

print("\n✅ test_single_source_playhead.lua passed")
