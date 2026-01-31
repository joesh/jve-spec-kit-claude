--- Test: timeline_playback applies audio_to_timeline_offset_us
--
-- Regression: In timeline mode, audio runs in source time (e.g. 0-5s within a clip),
-- but playhead is in timeline time (e.g. 30-35s). Without offset correction,
-- get_media_time_us() returns source time → playhead jumps to frame 0.
--
-- The fix: timeline_playback.tick() must add tick_in.audio_to_timeline_offset_us
-- to source_time before computing frame position.

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
-- source_in = 0. So at timeline 31s (frame 775), source_time = 1s = 1000000us.
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
-- Test 1: tick with offset converts source→timeline time for frame position
--------------------------------------------------------------------------------
print("Test 1: audio source_time + offset → correct timeline frame")

-- Scenario: clip starts at timeline frame 750 (= 30s @ 25fps).
-- Audio reports source_time = 1000000us (1s into clip).
-- offset = 30000000 (30s).
-- Expected timeline_time = 1000000 + 30000000 = 31000000us = frame 775.

local mock_audio_source_time_us = 1000000  -- 1s in source time
local timeline_offset_us = 30000000        -- clip starts at 30s on timeline

local mock_audio = {
    playing = true,
    is_ready = function() return true end,
    get_media_time_us = function() return mock_audio_source_time_us end,
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
    audio_to_timeline_offset_us = timeline_offset_us,
}

displayed_times = {}
local result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)

-- Frame = floor(31000000 * 25 / 1000000) = floor(775) = 775
assert(result.new_pos == 775,
    string.format("Expected frame 775 (31s @ 25fps), got %s", tostring(result.new_pos)))
assert(result.continue == true, "Should continue")
print(string.format("  pos=%d (expected 775) ✓", result.new_pos))

--------------------------------------------------------------------------------
-- Test 2: without offset (or offset=0), source time IS timeline time (source mode equiv)
--------------------------------------------------------------------------------
print("Test 2: offset=0 → source time used directly")

tick_in.audio_to_timeline_offset_us = 0
mock_audio_source_time_us = 2000000  -- 2s

displayed_times = {}
result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)

-- Frame = floor(2000000 * 25 / 1000000) = 50
assert(result.new_pos == 50,
    string.format("Expected frame 50 (2s @ 25fps), got %s", tostring(result.new_pos)))
print(string.format("  pos=%d (expected 50) ✓", result.new_pos))

--------------------------------------------------------------------------------
-- Test 3: offset nil (backward compat) treated as 0
--------------------------------------------------------------------------------
print("Test 3: offset=nil → treated as 0 (backward compat)")

tick_in.audio_to_timeline_offset_us = nil
mock_audio_source_time_us = 3000000  -- 3s

result = timeline_playback.tick(tick_in, mock_audio, mock_viewer)

-- Frame = floor(3000000 * 25 / 1000000) = 75
assert(result.new_pos == 75,
    string.format("Expected frame 75 (3s @ 25fps), got %s", tostring(result.new_pos)))
print(string.format("  pos=%d (expected 75) ✓", result.new_pos))

--------------------------------------------------------------------------------
-- Test 4: no audio (fallback path) — offset irrelevant
--------------------------------------------------------------------------------
print("Test 4: no audio → frame-based advancement (offset irrelevant)")

tick_in.audio_to_timeline_offset_us = 30000000
tick_in.pos = 100

result = timeline_playback.tick(tick_in, nil, mock_viewer)

-- No audio → pos = 100 + 1*1 = 101
assert(result.new_pos == 101,
    string.format("Expected frame 101 (pos+dir*speed), got %s", tostring(result.new_pos)))
print(string.format("  pos=%d (expected 101) ✓", result.new_pos))

--------------------------------------------------------------------------------
print()
print("✅ test_timeline_audio_offset.lua passed")
