--- Test: Video follows audio time in shuttle mode (Rule V1)
--
-- Per AV-SYNC spec Rule V1: "When audio is active and playing:
-- t_vid_us = audio_playback.get_media_time_us()
-- frame = calc_frame_from_time_us(t_vid_us)"
--
-- Video should ALWAYS follow audio, regardless of transport_mode.
-- The shuttle vs play distinction only affects boundary behavior.

require("test_env")

-- Mock qt_constants (required by playback_controller and media_cache)
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

print("=== test_video_follows_audio_in_shuttle.lua ===")

-- Mock audio_playback with controlled time
local mock_audio_time_us = 0
local mock_audio = {
    session_initialized = true,
    source_loaded = true,
    has_audio = true,
    playing = true,
    get_media_time_us = function()
        return mock_audio_time_us
    end,
    is_ready = function() return true end,
    shutdown_session = function() end,
    set_max_media_time = function(max_us) end,
    set_max_time = function(max_us) end,
    set_audio_sources = function() end,
    get_time_us = function() return mock_audio_time_us end,
    seek = function(time_us) end,
    set_speed = function(speed) end,
    start = function() end,
    stop = function() end,
}

-- Mock viewer_panel
local displayed_frames = {}
local mock_viewer = {
    show_frame = function(frame_idx)
        table.insert(displayed_frames, frame_idx)
    end,
}

-- Mock media_cache
local mock_media_cache = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 25, fps_den = 1 } end,
}
package.loaded["core.media.media_cache"] = mock_media_cache

-- Prevent timer recursion
local timer_callbacks = {}
function qt_create_single_shot_timer(ms, callback)
    table.insert(timer_callbacks, callback)
end

-- Load playback_controller
package.loaded["ui.playback_controller"] = nil
local playback_controller = require("core.playback.playback_controller")

-- Initialize
playback_controller.init(mock_viewer)
playback_controller.init_audio(mock_audio)
playback_controller.set_source(1000, 25, 1)  -- 1000 frames at 25fps

-- Start shuttle mode at 1x forward
playback_controller.shuttle(1)
assert(playback_controller.transport_mode == "shuttle", "Should be in shuttle mode")
assert(playback_controller.state == "playing", "Should be playing")

-- Clear displayed frames
displayed_frames = {}

-- Simulate audio time advancing to 2 seconds (frame 50 at 25fps)
mock_audio_time_us = 2000000  -- 2 seconds

-- Run a tick
playback_controller._tick()

-- THE ACTUAL TEST:
-- Video frame should match audio time (2 seconds = frame 50)
-- NOT advance by 1 from wherever it was
local expected_frame = 50  -- 2 seconds * 25fps
local actual_frame = displayed_frames[#displayed_frames]

print(string.format("  Audio time: %.3f s", mock_audio_time_us / 1000000))
print(string.format("  Expected frame: %d", expected_frame))
print(string.format("  Actual frame: %d", actual_frame or -1))

-- This assertion should FAIL without the fix
assert(actual_frame == expected_frame,
    string.format("FAIL: Video should follow audio! Expected frame %d, got %d. " ..
        "Video is not following audio_playback.get_media_time_us() as spec requires.",
        expected_frame, actual_frame or -1))

print("✅ test_video_follows_audio_in_shuttle.lua passed")
