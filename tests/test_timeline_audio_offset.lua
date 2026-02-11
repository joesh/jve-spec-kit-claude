--- Test: timeline_playback uses audio_playback.get_time_us() for timeline time
--
-- Architecture: audio_playback.get_time_us() returns timeline time directly.
-- timeline_playback.tick() uses this value as-is to compute frame position.
-- No offset conversion needed — audio tracks timeline time natively.

require("test_env")

print("=== test_timeline_audio_offset.lua ===")

-- Mock qt_constants
local mock_qt_constants = {
    EMP = {
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
local activated_paths = {}
local mock_media_cache = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 25, fps_den = 1 } end,
    activate = function(path) table.insert(activated_paths, path) end,
}
package.loaded["core.media.media_cache"] = mock_media_cache

-- Mock timeline_resolver: clip starts at timeline frame 750 (30s @ 25fps),
-- source_in = 0. Resolver returns source_time for decode purposes.
local mock_clip = { id = "clip_A" }
local mock_resolver_result = {
    media_path = "/media/clip_a.mov",
    source_time_us = 1000000,  -- 1 second into clip
    clip = mock_clip,
}
package.loaded["core.playback.timeline_resolver"] = {
    resolve_at_time = function(playhead_rat, sequence_id)
        return mock_resolver_result
    end,
}

-- Prevent timer creation
_G.qt_create_single_shot_timer = function() end

-- Mock viewer
local displayed_times = {}
local gap_count = 0
local mock_viewer = {
    show_frame_at_time = function(t_us)
        table.insert(displayed_times, t_us)
    end,
    show_gap = function()
        gap_count = gap_count + 1
    end,
}

-- Load timeline_playback fresh
package.loaded["core.playback.timeline_playback"] = nil
local timeline_playback = require("core.playback.timeline_playback")

--------------------------------------------------------------------------------
-- Test 1: tick uses get_time_us() (timeline time) directly for frame position
--------------------------------------------------------------------------------
print("Test 1: audio returns timeline time → correct frame")

-- Scenario: clip starts at timeline frame 750 (= 30s @ 25fps).
-- Audio reports timeline_time = 31000000us (31s on timeline).
-- Expected frame = floor(31000000 * 25 / 1000000) = 775.

local mock_audio_time_us = 31000000  -- 31s timeline time

local mock_audio = {
    playing = true,
    has_audio = true,  -- has audio sources at current position
    is_ready = function() return true end,
    get_time_us = function() return mock_audio_time_us end,
    get_media_time_us = function() return mock_audio_time_us end,  -- alias
    set_speed = function() end,
    set_source = function() end,
}

local tick_in = {
    pos = 774,  -- previous frame (doesn't matter when audio is master)
    direction = 1,
    speed = 1,
    fps_num = 25,
    fps_den = 1,
    total_frames = 90000,  -- 1 hour
    sequence_id = "seq_1",
    current_clip_id = "clip_A",
}

displayed_times = {}
local result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)

-- Frame = floor(31000000 * 25 / 1000000) = floor(775) = 775
assert(result.new_pos == 775,
    string.format("Expected frame 775 (31s @ 25fps), got %s", tostring(result.new_pos)))
assert(result.continue == true, "Should continue")
print(string.format("  pos=%d (expected 775) ✓", result.new_pos))

--------------------------------------------------------------------------------
-- Test 2: audio returns a different timeline time → correct frame
--------------------------------------------------------------------------------
print("Test 2: audio returns 2s timeline time → frame 50")

mock_audio_time_us = 2000000  -- 2s timeline time

displayed_times = {}
result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)

-- Frame = floor(2000000 * 25 / 1000000) = 50
assert(result.new_pos == 50,
    string.format("Expected frame 50 (2s @ 25fps), got %s", tostring(result.new_pos)))
print(string.format("  pos=%d (expected 50) ✓", result.new_pos))

--------------------------------------------------------------------------------
-- Test 3: audio returns 3s timeline time → frame 75
--------------------------------------------------------------------------------
print("Test 3: audio returns 3s timeline time → frame 75")

mock_audio_time_us = 3000000  -- 3s timeline time

result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)

-- Frame = floor(3000000 * 25 / 1000000) = 75
assert(result.new_pos == 75,
    string.format("Expected frame 75 (3s @ 25fps), got %s", tostring(result.new_pos)))
print(string.format("  pos=%d (expected 75) ✓", result.new_pos))

--------------------------------------------------------------------------------
-- Test 4: no audio → frame-based advancement
--------------------------------------------------------------------------------
print("Test 4: no audio → frame-based advancement")

tick_in.pos = 100

result = timeline_playback.tick(tick_in, nil, mock_viewer)

-- No audio → pos = 100 + 1*1 = 101
assert(result.new_pos == 101,
    string.format("Expected frame 101 (pos+dir*speed), got %s", tostring(result.new_pos)))
print(string.format("  pos=%d (expected 101) ✓", result.new_pos))

--------------------------------------------------------------------------------
print()
print("✅ test_timeline_audio_offset.lua passed")
