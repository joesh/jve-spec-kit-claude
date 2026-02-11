#!/usr/bin/env luajit
-- Regression test: audio must start when entering a clip from a gap.
--
-- BUG: Play from gap → audio sources change from 0 to N → but audio
-- never starts because set_audio_sources only restarts if was_playing=true.
-- When entering from a gap, audio was NOT playing (no sources), so the
-- restart is skipped. Result: video plays, no sound.
--
-- FIX: After set_audio_sources, if controller is playing and audio has
-- sources but isn't playing, call start_audio().

require('test_env')

-- Track audio operations
local audio_ops = {
    set_sources_calls = {},
    start_calls = 0,
    seek_calls = {},
    set_speed_calls = {},
    playing = false,
    time_us = 0,
}

local function reset_audio_ops()
    audio_ops.set_sources_calls = {}
    audio_ops.start_calls = 0
    audio_ops.seek_calls = {}
    audio_ops.set_speed_calls = {}
    audio_ops.playing = false
    audio_ops.time_us = 0
end

-- Build mock audio_playback that tracks operations
local mock_audio = {
    session_initialized = true,
    has_audio = false,
    playing = false,
    media_time_us = 0,
    speed = 1.0,
    quality_mode = 1,
    max_media_time_us = 10000000,
    audio_sources = {},
    media_cache_ref = nil,
    aop = "mock_aop",
    sse = "mock_sse",
    session_sample_rate = 48000,
    session_channels = 2,
}

function mock_audio.is_ready()
    return mock_audio.session_initialized and mock_audio.has_audio
end

function mock_audio.get_time_us()
    return audio_ops.time_us
end

function mock_audio.get_media_time_us()
    return audio_ops.time_us
end

function mock_audio.set_audio_sources(sources, cache, restart_time_us)
    table.insert(audio_ops.set_sources_calls, {
        count = #sources,
        restart_time_us = restart_time_us,
    })
    mock_audio.audio_sources = sources
    mock_audio.has_audio = #sources > 0
    -- Simulate the real set_audio_sources cold path behavior:
    -- It does NOT start audio if was_playing=false (the bug!)
    -- The fix should be in the CALLER (playback_controller), not here.
end

function mock_audio.start()
    audio_ops.start_calls = audio_ops.start_calls + 1
    mock_audio.playing = true
end

function mock_audio.stop()
    mock_audio.playing = false
end

function mock_audio.seek(time_us)
    table.insert(audio_ops.seek_calls, time_us)
    mock_audio.media_time_us = time_us
end

function mock_audio.set_speed(speed)
    table.insert(audio_ops.set_speed_calls, speed)
    mock_audio.speed = speed
end

function mock_audio.set_max_time(max_us)
    mock_audio.max_media_time_us = max_us
end

function mock_audio.set_max_media_time(max_us)
    mock_audio.max_media_time_us = max_us
end

function mock_audio.latch() end
function mock_audio.shutdown_session() end

-- Mock qt_constants
local mock_qt = {
    EMP = { SET_DECODE_MODE = function() end },
    SSE = {},
    AOP = {},
}
package.loaded["core.qt_constants"] = mock_qt

-- Mock media_cache
local mock_media_cache = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 24, fps_den = 1, rotation = 0, has_audio = true, audio_sample_rate = 48000 } end,
    get_file_path = function() return "/test/clip.wav" end,
    stop_all_prefetch = function() end,
    activate = function() end,
    ensure_audio_pooled = function(path)
        return { has_audio = true, audio_sample_rate = 48000, duration_us = 5000000, start_tc = 0 }
    end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
}
package.loaded["core.media.media_cache"] = mock_media_cache
package.loaded["ui.media_cache"] = mock_media_cache

-- Mock timeline_resolver
local resolver_audio_clips = {}  -- Test controls what clips are returned
local mock_resolver = {
    resolve_at_time = function(frame_idx, sequence_id)
        -- Always return a video clip (we're testing audio)
        return {
            clip = { id = "video_clip_1" },
            media_path = "/test/clip.mov",
            source_time_us = frame_idx * 1000000 / 24,
        }
    end,
    resolve_all_audio_at_time = function(frame_idx, sequence_id)
        return resolver_audio_clips
    end,
}
package.loaded["core.playback.timeline_resolver"] = mock_resolver

-- Mock helpers
local real_helpers = require("core.playback.playback_helpers")
-- sync_audio calls set_speed on audio
real_helpers.sync_audio = function(ap, dir, speed)
    if ap and ap.set_speed then ap.set_speed(dir * speed) end
end
real_helpers.stop_audio = function(ap)
    if ap and ap.stop then ap.stop() end
end

-- Mock viewer
local mock_viewer = {
    show_frame_at_time = function() end,
    show_frame = function() end,
    show_gap = function() end,
    set_rotation = function() end,
    has_media = function() return true end,
}

-- Mock timeline_state
local playhead = 0
local mock_timeline_state = {
    get_playhead_position = function() return playhead end,
    set_playhead_position = function(v) playhead = v end,
    get_sequence_frame_rate = function()
        return { fps_numerator = 24, fps_denominator = 1 }
    end,
}
package.loaded["ui.timeline.timeline_state"] = mock_timeline_state

-- Mock source_viewer_state
package.loaded["ui.source_viewer_state"] = {
    has_clip = function() return false end,
    set_playhead = function() end,
}

-- Mock clip_state for content_end
package.loaded["ui.timeline.state.clip_state"] = {
    get_content_end_frame = function() return 100 end,
}

-- Mock signals
package.loaded["core.signals"] = {
    connect = function() end,
    emit = function() end,
}

-- Mock timer
_G.qt_create_single_shot_timer = function(interval, callback) end

-- Load playback_controller (after all mocks)
package.loaded["core.playback.playback_controller"] = nil
local pc = require("core.playback.playback_controller")

print("=== Test: Audio starts after gap ===")

--------------------------------------------------------------------------------
-- Setup: controller in timeline mode, playing, no audio initially (gap)
--------------------------------------------------------------------------------
pc.init(mock_viewer)
pc.init_audio(mock_audio)
pc.set_source(100, 24, 1)
pc.set_timeline_mode(true, "seq_1")

-- Start playing (from gap, no audio)
reset_audio_ops()
resolver_audio_clips = {}  -- No audio clips (gap)

pc.play()
assert(pc.state == "playing", "Controller should be playing")
assert(not mock_audio.playing, "Audio should NOT be playing (gap, no sources)")
print("  Setup: playing in gap, no audio sources")

--------------------------------------------------------------------------------
-- TEST: Simulate entering a clip — audio sources appear
--------------------------------------------------------------------------------
print("\nTest 1: Audio sources appear during playback → audio must start")

-- Now the resolver returns an audio clip (we've entered a clip)
resolver_audio_clips = {
    {
        clip = {
            id = "audio_clip_1",
            timeline_start = 3,
            source_in = 0,
            source_out = 48000,
            rate = { fps_numerator = 48000, fps_denominator = 1 },
        },
        media_path = "/test/clip.wav",
        track = { muted = false, soloed = false, volume = 1.0 },
    }
}

-- Simulate what _tick does: call resolve_and_set_audio_sources
-- (We call the function directly since _tick has many dependencies)
-- First, we need to access the local function. It's not exported.
-- Instead, let's drive _tick by setting up the right state.

-- Set position to frame 3 (start of clip)
playhead = 3
pc._position = 3
pc._last_committed_frame = 3
pc._last_tick_frame = 2  -- Previous frame was in gap
pc._last_audio_frame = nil

-- Run a tick
reset_audio_ops()
pc._tick()

-- After the tick, audio should have been started
assert(mock_audio.playing,
    "Audio must be playing after entering clip from gap")
assert(audio_ops.start_calls > 0,
    "audio.start() must have been called, got " .. audio_ops.start_calls .. " calls")
print("  ✓ Audio started when sources appeared during playback")

--------------------------------------------------------------------------------
-- TEST 2: Audio was already playing → no double-start
--------------------------------------------------------------------------------
print("\nTest 2: Audio already playing → no extra start call")

reset_audio_ops()
mock_audio.playing = true  -- Already playing from test 1

-- Tick again with same sources (no change)
pc._last_tick_frame = 3
pc._last_audio_frame = nil
audio_ops.time_us = 3 * 1000000 / 24  -- Audio at frame 3

pc._tick()

-- Should NOT call start again (audio already playing, sources unchanged)
assert(audio_ops.start_calls == 0,
    "Should not call start() when audio already playing, got " .. audio_ops.start_calls)
print("  ✓ No double-start when audio already playing")

pc.stop()

print("\n✅ test_audio_starts_after_gap.lua passed")
