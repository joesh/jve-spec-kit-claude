-- test_reverse_playback_clip_boundary.lua
--
-- Regression test: Audio must clamp restart time to new clip boundaries
-- when crossing clip boundaries during reverse playback.
--
-- Bug: Playing in reverse at 1x, when crossing from clip A (ends at 3771.6s)
-- into clip B (ends at 3771.517s), the audio would starve because:
-- 1. restart_time_us was set to old position (3771.6s)
-- 2. New clip's clip_end_us was 3771.517s
-- 3. SSE was reanchored at 3771.6s (past clip boundary)
-- 4. PCM cache only covered up to 3771.517s
-- 5. SSE couldn't find audio at 3771.6s → permanent starvation
--
-- Fix: set_audio_sources() now clamps restart time to new clip boundaries
-- before reanchoring.

require("test_env")

-- Mock qt_constants for testing - must be set up BEFORE requiring audio_playback
-- Inject mocks into the package.loaded cache that qt_constants will use
local mock_sse = { render_pos = 0 }
local mock_aop = { playhead = 0, stopped = true, flushed = false }

local mock_qt_constants = {
    AOP = {
        OPEN = function() return mock_aop, nil end,
        CLOSE = function() end,
        START = function(aop) aop.stopped = false end,
        STOP = function(aop) aop.stopped = true end,
        FLUSH = function(aop) aop.flushed = true end,
        WRITE_F32 = function() return 0 end,
        PLAYHEAD_US = function(aop) return aop.playhead end,
        BUFFERED_FRAMES = function() return 0 end,
        HAD_UNDERRUN = function() return false end,
        CLEAR_UNDERRUN = function() end,
        SAMPLE_RATE = function() return 48000 end,
        CHANNELS = function() return 2 end,
    },
    SSE = {
        CREATE = function() return mock_sse end,
        CLOSE = function() end,
        RESET = function() end,
        SET_TARGET = function(sse, time_us) sse.render_pos = time_us end,
        CURRENT_TIME_US = function(sse) return sse.render_pos end,
        RENDER_ALLOC = function() return nil, 0 end,
        PUSH_PCM = function() end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
    },
    EMP = {
        SET_DECODE_MODE = function() end,
    },
}

-- Pre-populate package.loaded before audio_playback requires qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

-- Clear any previously loaded audio_playback to ensure fresh load with mocks
package.loaded["core.media.audio_playback"] = nil

_G.qt_create_single_shot_timer = function() end

-- Now require audio_playback - it will get our mocked qt_constants
local audio_playback = require("core.media.audio_playback")

-- Mock media_cache
local mock_cache = {
    get_audio_pcm_for_path = function(path, start_us, end_us, sample_rate)
        -- Return mock PCM data
        local ffi = require("ffi")
        local frames = math.floor((end_us - start_us) * sample_rate / 1000000)
        frames = math.max(frames, 1)  -- At least 1 frame
        local buf = ffi.new("float[?]", frames * 2)
        return buf, frames, start_us
    end,
}

-- Test: reverse playback entering clip from right edge
print("Test: reverse playback clamps restart time to clip_end...")

-- Initialize session
audio_playback.init_session(48000, 2)
audio_playback.set_max_time(10000000)  -- 10 seconds max

-- Simulate active reverse playback at old clip position
audio_playback.media_time_us = 3771601  -- 3.771601s (past new clip end)
audio_playback.speed = -1.0  -- Reverse playback
audio_playback.quality_mode = 1
audio_playback.playing = true  -- Must be playing for clamping to apply

-- New clip ends at 3771517 us (3.771517s)
local new_sources = {
    {
        path = "/mock/audio.wav",
        source_offset_us = 0,
        seek_us = 0,
        speed_ratio = 1.0,
        volume = 1.0,
        duration_us = 1000000,  -- 1 second
        clip_start_us = 2771517,  -- clip starts 1 second before end
        clip_end_us = 3771517,  -- clip ends at 3.771517s
    }
}

-- Set new sources (this should clamp media_time_us to clip_end_us)
audio_playback.set_audio_sources(new_sources, mock_cache)

-- Verify: media_time_us should be clamped to clip_end_us (3771517)
assert(audio_playback.media_time_us <= 3771517,
    string.format("Expected media_time_us <= 3771517, got %d", audio_playback.media_time_us))

print("  PASS: restart time clamped to clip_end for reverse entry")

-- Test: forward playback entering clip from left edge
print("Test: forward playback clamps restart time to clip_start...")

-- Reset session
audio_playback.shutdown_session()
audio_playback.init_session(48000, 2)
audio_playback.set_max_time(10000000)

-- Simulate active forward playback at position before new clip start
audio_playback.media_time_us = 1000000  -- 1s (before new clip start)
audio_playback.speed = 1.0  -- Forward playback
audio_playback.quality_mode = 1
audio_playback.playing = true  -- Must be playing for clamping to apply

-- New clip starts at 2000000 us (2s)
new_sources = {
    {
        path = "/mock/audio.wav",
        source_offset_us = 0,
        seek_us = 0,
        speed_ratio = 1.0,
        volume = 1.0,
        duration_us = 1000000,  -- 1 second
        clip_start_us = 2000000,  -- clip starts at 2s
        clip_end_us = 3000000,  -- clip ends at 3s
    }
}

-- Set new sources (this should clamp media_time_us to clip_start_us)
audio_playback.set_audio_sources(new_sources, mock_cache)

-- Verify: media_time_us should be clamped to clip_start_us (2000000)
assert(audio_playback.media_time_us >= 2000000,
    string.format("Expected media_time_us >= 2000000, got %d", audio_playback.media_time_us))

print("  PASS: restart time clamped to clip_start for forward entry")

-- Test: multiple clips use intersection of boundaries
print("Test: multiple clips use intersection of boundaries...")

audio_playback.shutdown_session()
audio_playback.init_session(48000, 2)
audio_playback.set_max_time(10000000)

-- Simulate active reverse playback past the first clip's end
audio_playback.media_time_us = 3500000  -- 3.5s
audio_playback.speed = -1.0  -- Reverse
audio_playback.quality_mode = 1
audio_playback.playing = true  -- Must be playing for clamping to apply

-- Two clips with different boundaries
new_sources = {
    {
        path = "/mock/audio1.wav",
        source_offset_us = 0,
        seek_us = 0,
        speed_ratio = 1.0,
        volume = 1.0,
        duration_us = 1000000,
        clip_start_us = 2000000,  -- 2s
        clip_end_us = 3000000,  -- 3s (this is the tighter constraint)
    },
    {
        path = "/mock/audio2.wav",
        source_offset_us = 0,
        seek_us = 0,
        speed_ratio = 1.0,
        volume = 1.0,
        duration_us = 2000000,
        clip_start_us = 1500000,  -- 1.5s
        clip_end_us = 4000000,  -- 4s
    }
}

audio_playback.set_audio_sources(new_sources, mock_cache)

-- Verify: should clamp to min(clip_end_us) = 3000000
assert(audio_playback.media_time_us <= 3000000,
    string.format("Expected media_time_us <= 3000000 (min clip_end), got %d", audio_playback.media_time_us))

print("  PASS: restart time clamped to min(clip_end) for multiple clips")

-- Cleanup
audio_playback.shutdown_session()

print("✅ test_reverse_playback_clip_boundary.lua passed")
