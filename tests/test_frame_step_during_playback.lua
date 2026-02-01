--- Test: external playhead move during playback re-anchors audio
--
-- Regression: During timeline playback, audio_playback.get_time_us() is master
-- clock. timeline_playback.tick() derives position from audio time and writes
-- to timeline_state. An external write (frame-forward, go-to-edit, ruler click,
-- undo) is overwritten by the next tick ~16ms later.
--
-- Fix: playback_controller tracks _last_committed_frame. Each tick compares
-- timeline_state position to _last_committed_frame; if different, re-anchors
-- audio at the new position before proceeding with normal tick.

require("test_env")

print("=== test_frame_step_during_playback.lua ===")

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

-- Mock logger
package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 24, fps_den = 1, has_audio = true, duration_us = 10000000 } end,
    activate = function() end,
    ensure_audio_pooled = function(path)
        return { has_audio = true, audio_sample_rate = 48000, duration_us = 10000000 }
    end,
    get_file_path = function() return "/mock/media.mov" end,
}

-- Mock timeline_resolver
package.loaded["core.playback.timeline_resolver"] = {
    resolve_at_time = function(playhead_rat, sequence_id)
        return {
            clip = { id = "clip_001" },
            media_path = "/mock/media.mov",
            source_time_us = 0,
        }
    end,
    resolve_all_audio_at_time = function()
        return {}  -- No audio clips for simplicity
    end,
}

-- Mock viewer
local frames_shown = {}
local mock_viewer = {
    show_frame = function(idx) table.insert(frames_shown, idx) end,
    show_frame_at_time = function(t) table.insert(frames_shown, "t:" .. t) end,
    show_gap = function() table.insert(frames_shown, "gap") end,
    has_media = function() return true end,
}

-- Prevent timer recursion
_G.qt_create_single_shot_timer = function() end

-- Track audio events
local audio_events = {}
local mock_audio_time_us = 0

local mock_audio = {
    session_initialized = true,
    source_loaded = true,
    has_audio = true,
    playing = false,
    speed = 0,
    media_time_us = 0,
    max_media_time_us = 0,
}

function mock_audio.is_ready() return true end
function mock_audio.set_max_media_time(v) mock_audio.max_media_time_us = v end
function mock_audio.set_max_time(v) mock_audio.max_media_time_us = v end
function mock_audio.set_audio_sources() end

function mock_audio.start()
    mock_audio.playing = true
    table.insert(audio_events, "start")
end

function mock_audio.stop()
    mock_audio.playing = false
    table.insert(audio_events, "stop")
end

function mock_audio.seek(time_us)
    mock_audio.media_time_us = time_us
    mock_audio_time_us = time_us
    table.insert(audio_events, "seek:" .. time_us)
end

function mock_audio.set_speed(speed)
    mock_audio.speed = speed
    table.insert(audio_events, "speed:" .. speed)
end

function mock_audio.get_media_time_us()
    return mock_audio_time_us
end

function mock_audio.get_time_us()
    return mock_audio_time_us
end

-- Mock timeline_state for timeline mode (uses real Rational for rescale support)
local Rational = require("core.rational")
local mock_playhead_position = Rational.new(0, 24, 1)
local mock_timeline_state = {
    get_playhead_position = function()
        return mock_playhead_position
    end,
    set_playhead_position = function(rat)
        mock_playhead_position = rat
    end,
    get_sequence_frame_rate = function()
        return { fps_numerator = 24, fps_denominator = 1 }
    end,
}
package.loaded["ui.timeline.timeline_state"] = mock_timeline_state

-- Load playback modules fresh
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
local pc = require("core.playback.playback_controller")

pc.init(mock_viewer)
pc.init_audio(mock_audio)

-- Enter timeline mode
pc.set_timeline_mode(true, "seq_001", { fps_num = 24, fps_den = 1, total_frames = 1000 })

--------------------------------------------------------------------------------
-- Test 1: External playhead move during playback re-anchors audio
--------------------------------------------------------------------------------
print("Test 1: external playhead move during playback re-anchors audio")

-- Start playback at frame 0
mock_playhead_position = Rational.new(0, 24, 1)
pc.play()
assert(pc.state == "playing", "Should be playing")

-- Simulate audio advancing to frame 10.
-- calc_time_us_from_frame(10,24,1) = floor(10*1e6/24) = 416666
-- calc_frame_from_time_us(416666,24,1) = floor(416666*24/1e6) = floor(9.999984) = 9
-- This is the standard frame↔us rounding. Use frame 10's us + 1 to land on frame 10.
local helpers = require("core.playback.playback_helpers")
local frame10_us = helpers.calc_time_us_from_frame(10, 24, 1) + 1
mock_audio_time_us = frame10_us

-- First tick: audio-derived position → frame 10, committed
audio_events = {}
pc._tick()
local pos_after_first_tick = pc.get_position()
assert(pos_after_first_tick == 10,
    string.format("After first tick, position should be 10, got %d", pos_after_first_tick))

-- Now simulate external move: user presses frame-forward, writing directly
-- to timeline_state (bypassing playback_controller)
mock_playhead_position = Rational.new(50, 24, 1)
-- Audio still reports old time (frame 10 area)
-- mock_audio_time_us stays at frame 10

-- Next tick should detect external move and re-anchor audio at frame 50
audio_events = {}
pc._tick()

-- Verify audio was seeked to frame 50's time
local expected_time_us = helpers.calc_time_us_from_frame(50, 24, 1)
local saw_seek_to_new_pos = false
for _, ev in ipairs(audio_events) do
    if ev == "seek:" .. expected_time_us then
        saw_seek_to_new_pos = true
    end
end
assert(saw_seek_to_new_pos,
    string.format("Audio must be seeked to frame 50 time (%dus), events: %s",
        expected_time_us, table.concat(audio_events, ", ")))

-- Position should now be at or near frame 50 (not snapped back to ~10)
local pos_after_external_move = pc.get_position()
assert(pos_after_external_move >= 49 and pos_after_external_move <= 51,
    string.format("After external move to 50, position should be ~50, got %d (would be ~10 without fix)",
        pos_after_external_move))

print("  events: " .. table.concat(audio_events, ", "))
print("  ✓ external move detected, audio re-anchored at new position")

--------------------------------------------------------------------------------
-- Test 2: Normal tick (no external move) does NOT trigger re-anchor
--------------------------------------------------------------------------------
print("Test 2: normal tick without external move — no spurious re-anchor")

-- Advance audio to frame 55
mock_audio_time_us = helpers.calc_time_us_from_frame(55, 24, 1) + 1
audio_events = {}
pc._tick()

-- Should NOT see a seek event (normal advancement, no external move)
local saw_any_seek = false
for _, ev in ipairs(audio_events) do
    if ev:match("^seek:") then saw_any_seek = true end
end
assert(not saw_any_seek,
    "Normal tick should NOT trigger audio seek, events: " .. table.concat(audio_events, ", "))

local pos_normal = pc.get_position()
assert(pos_normal == 55,
    string.format("Normal tick should advance to frame 55, got %d", pos_normal))

print("  ✓ no spurious re-anchor on normal tick")

--------------------------------------------------------------------------------
-- Test 3: _last_committed_frame resets on stop
--------------------------------------------------------------------------------
print("Test 3: _last_committed_frame resets on stop")

pc.stop()
assert(pc._last_committed_frame == nil,
    "_last_committed_frame should be nil after stop")

print("  ✓ _last_committed_frame cleared on stop")

--------------------------------------------------------------------------------
print()
print("✅ test_frame_step_during_playback.lua passed")
