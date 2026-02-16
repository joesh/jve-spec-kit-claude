#!/usr/bin/env luajit
--- Test: PlaybackEngine lookahead pre-buffers next clip near edit points.
--
-- Video lookahead: 1-second threshold before clip_end_frame.
-- Audio lookahead: 2-second threshold before clip_end_us.
-- Pre-buffer is called once per approaching clip (no re-fire on subsequent ticks).
--
-- @file test_engine_lookahead.lua

require('test_env')

print("=== test_engine_lookahead.lua ===")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(_, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end
local function pump_tick()
    assert(#timer_callbacks > 0, "pump_tick: no pending timer callback")
    local cb = table.remove(timer_callbacks, 1)
    cb()
end
local function clear_timers() timer_callbacks = {} end

-- Pre-buffer call tracking
local video_pre_buffer_calls = {}
local audio_pre_buffer_calls = {}
local function reset_logs()
    video_pre_buffer_calls = {}
    audio_pre_buffer_calls = {}
end

package.loaded["core.qt_constants"] = {
    EMP = { SET_DECODE_MODE = function() end },
}

package.loaded["core.media.media_cache"] = {
    activate = function() return { rotation = 0, start_tc = 0 } end,
    get_video_frame = function(frame) return "frame_" .. frame end,
    set_playhead = function() end,
    stop_all_prefetch = function() end,
    ensure_audio_pooled = function()
        return { has_audio = true, audio_sample_rate = 48000 }
    end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
    pre_buffer = function(path, entry_frame, fps_num, fps_den)
        video_pre_buffer_calls[#video_pre_buffer_calls + 1] = {
            path = path, entry_frame = entry_frame,
            fps_num = fps_num, fps_den = fps_den,
        }
    end,
}

package.loaded["core.logger"] = {
    debug = function() end, info = function() end,
    warn = function() end, error = function() end, trace = function() end,
}
package.loaded["core.signals"] = {
    connect = function() end, emit = function() end,
}
package.loaded["core.project_generation"] = {
    current = function() return 1 end,
    check = function() end,
}

-- Two clips: clip_a (frames 0-99), clip_b (frames 100-199)
local mock_sequence = {
    id = "seq1",
    compute_content_end = function() return 200 end,
    get_next_video = function(self, after_frame)
        if after_frame == 100 then
            return {{
                media_path = "/clip_b.mov",
                source_frame = 0,
                clip = {
                    id = "clip_b",
                    rate = { fps_numerator = 24, fps_denominator = 1 },
                    timeline_start = 100, duration = 100, source_in = 0,
                },
                track = { id = "track_v1" },
            }}
        end
        return {}
    end,
    get_prev_video = function(self, before_frame)
        if before_frame == 100 then
            return {{
                media_path = "/clip_a.mov",
                source_frame = 99,
                clip = {
                    id = "clip_a",
                    rate = { fps_numerator = 24, fps_denominator = 1 },
                    timeline_start = 0, duration = 100, source_in = 0,
                },
                track = { id = "track_v1" },
            }}
        end
        return {}
    end,
    get_next_audio = function(self, after_frame)
        if after_frame == 100 then
            return {{
                media_path = "/clip_b.wav",
                source_time_us = 0,
                source_frame = 0,
                clip = {
                    id = "aclip_b",
                    rate = { fps_numerator = 48000, fps_denominator = 1 },
                    timeline_start = 100, duration = 100,
                    source_in = 0, speed_ratio = 1.0, volume = 1.0,
                },
                track = { id = "track_a1" },
            }}
        end
        return {}
    end,
    get_prev_audio = function() return {} end,
}

package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

-- Renderer returns metadata WITH clip bounds (from Task 3)
package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 24, fps_den = 1,
            kind = "timeline", name = "Test",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function(seq, frame, ctx_id)
        if frame >= 0 and frame < 100 then
            return "frame_" .. frame, {
                clip_id = "clip_a", media_path = "/clip_a.mov",
                source_frame = frame, rotation = 0,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_end_frame = 100, clip_start_frame = 0,
            }
        elseif frame >= 100 and frame < 200 then
            return "frame_" .. frame, {
                clip_id = "clip_b", media_path = "/clip_b.mov",
                source_frame = frame - 100, rotation = 0,
                clip_fps_num = 24, clip_fps_den = 1,
                clip_end_frame = 200, clip_start_frame = 100,
            }
        end
        return nil, nil
    end,
}

-- Mixer: audio sources with clip boundaries
package.loaded["core.mixer"] = {
    resolve_audio_sources = function(seq, frame, fps_num, fps_den, mc)
        -- clip_a audio: 0-4166666us (frames 0-99 at 24fps)
        if frame >= 0 and frame < 100 then
            return {
                { path = "/clip_a.wav", source_offset_us = 0, seek_us = 0,
                  speed_ratio = 1.0, volume = 1.0,
                  duration_us = 4166666, clip_start_us = 0,
                  clip_end_us = 4166666, clip_id = "aclip_a" },
            }, { aclip_a = true }
        -- clip_b audio: 4166666-8333333us (frames 100-199 at 24fps)
        elseif frame >= 100 and frame < 200 then
            return {
                { path = "/clip_b.wav", source_offset_us = 4166666, seek_us = 0,
                  speed_ratio = 1.0, volume = 1.0,
                  duration_us = 4166666, clip_start_us = 4166666,
                  clip_end_us = 8333333, clip_id = "aclip_b" },
            }, { aclip_b = true }
        end
        return {}, {}
    end,
}

-- Mock audio_playback (is_ready=false so audio doesn't drive position)
local mock_audio
mock_audio = {
    session_initialized = true,
    playing = false,
    has_audio = false,
    max_media_time_us = 8333333,
    _time_us = 0,
    _project_gen = 1,

    is_ready = function() return false end,
    get_time_us = function() return mock_audio._time_us end,
    get_media_time_us = function() return mock_audio._time_us end,
    seek = function(t) mock_audio._time_us = t end,
    start = function() end,
    stop = function() mock_audio.playing = false end,
    set_speed = function() end,
    set_max_time = function() end,
    set_audio_sources = function(sources)
        mock_audio.has_audio = #sources > 0
    end,
    latch = function() end,
    play_burst = function() end,
    pre_buffer = function(source, cache)
        audio_pre_buffer_calls[#audio_pre_buffer_calls + 1] = {
            path = source.path,
            clip_start_us = source.clip_start_us,
            clip_end_us = source.clip_end_us,
        }
    end,
}

local PlaybackEngine = require("core.playback.playback_engine")
PlaybackEngine.init_audio(mock_audio)

local function make_engine()
    local log = { frames = {}, gaps = 0 }
    local engine = PlaybackEngine.new({
        media_context_id = "test_ctx",
        on_show_frame = function(fh, meta) log.frames[#log.frames + 1] = meta end,
        on_show_gap = function() log.gaps = log.gaps + 1 end,
        on_set_rotation = function() end,
        on_position_changed = function() end,
    })
    engine:load_sequence("seq1")
    engine:activate_audio()
    return engine, log
end

--------------------------------------------------------------------------------
-- Test 1: Video pre-buffer fires when approaching clip_end (forward)
--------------------------------------------------------------------------------

print("\n--- video pre-buffer near clip_end (forward) ---")
do
    local engine = make_engine()
    reset_logs()

    -- Seek to frame 90: 10 frames from clip_a end (100)
    -- 10 frames at 24fps = 0.42s, well within 1-second video threshold
    engine:seek(90)
    clear_timers()

    engine:shuttle(1)
    pump_tick() -- frame-based advance: 90 → 91

    assert(#video_pre_buffer_calls > 0, string.format(
        "Expected video pre_buffer near clip_end, got %d calls",
        #video_pre_buffer_calls))
    assert(video_pre_buffer_calls[1].path == "/clip_b.mov", string.format(
        "Expected pre_buffer for /clip_b.mov, got %s",
        tostring(video_pre_buffer_calls[1].path)))
    -- Entry frame should be clip_b's source_frame at start (0)
    assert(video_pre_buffer_calls[1].entry_frame == 0,
        "Entry frame should be 0 (clip_b source_frame at start)")

    engine:stop()
    clear_timers()
    print("  video pre-buffer near clip_end passed")
end

--------------------------------------------------------------------------------
-- Test 2: Audio pre-buffer fires when approaching clip_end (forward)
--------------------------------------------------------------------------------

print("\n--- audio pre-buffer near clip_end (forward) ---")
do
    local engine = make_engine()
    reset_logs()

    -- Frame 91: time = 91/24 * 1e6 = 3791666us
    -- clip_a audio clip_end_us = 4166666us
    -- Distance = 375000us (0.375s) < 2s audio threshold → trigger
    engine:seek(90)
    clear_timers()

    engine:shuttle(1)
    pump_tick()

    assert(#audio_pre_buffer_calls > 0, string.format(
        "Expected audio pre_buffer near clip_end, got %d calls",
        #audio_pre_buffer_calls))
    assert(audio_pre_buffer_calls[1].path == "/clip_b.wav", string.format(
        "Expected audio pre_buffer for /clip_b.wav, got %s",
        tostring(audio_pre_buffer_calls[1].path)))

    engine:stop()
    clear_timers()
    print("  audio pre-buffer near clip_end passed")
end

--------------------------------------------------------------------------------
-- Test 3: No re-pre-buffer for same clip on subsequent ticks
--------------------------------------------------------------------------------

print("\n--- no re-pre-buffer for same clip ---")
do
    local engine = make_engine()
    reset_logs()

    engine:seek(90)
    clear_timers()

    engine:shuttle(1)
    pump_tick() -- tick 1: advances to 91, pre-buffers clip_b

    local video_count = #video_pre_buffer_calls
    local audio_count = #audio_pre_buffer_calls
    assert(video_count > 0, "First tick should trigger video pre-buffer")
    assert(audio_count > 0, "First tick should trigger audio pre-buffer")

    pump_tick() -- tick 2: advances to 92, should NOT re-pre-buffer

    assert(#video_pre_buffer_calls == video_count, string.format(
        "Second tick should not re-pre-buffer video: expected %d, got %d",
        video_count, #video_pre_buffer_calls))
    assert(#audio_pre_buffer_calls == audio_count, string.format(
        "Second tick should not re-pre-buffer audio: expected %d, got %d",
        audio_count, #audio_pre_buffer_calls))

    engine:stop()
    clear_timers()
    print("  no re-pre-buffer for same clip passed")
end

--------------------------------------------------------------------------------
-- Test 4: No pre-buffer when far from boundary
--------------------------------------------------------------------------------

print("\n--- no pre-buffer far from boundary ---")
do
    local engine = make_engine()
    reset_logs()

    -- Frame 10: 90 frames from clip_end = 3.75s at 24fps
    -- Well outside both thresholds (1s video, 2s audio)
    engine:seek(10)
    clear_timers()

    engine:shuttle(1)
    pump_tick() -- advances to 11

    assert(#video_pre_buffer_calls == 0, string.format(
        "Should not pre-buffer far from boundary, got %d video calls",
        #video_pre_buffer_calls))
    assert(#audio_pre_buffer_calls == 0, string.format(
        "Should not pre-buffer far from boundary, got %d audio calls",
        #audio_pre_buffer_calls))

    engine:stop()
    clear_timers()
    print("  no pre-buffer far from boundary passed")
end

--------------------------------------------------------------------------------
-- Test 5: Pre-buffer clears when crossing into new clip
--------------------------------------------------------------------------------

print("\n--- pre-buffer resets on clip change ---")
do
    local engine = make_engine()
    reset_logs()

    -- Start near clip_a end, tick into clip_b
    engine:seek(98)
    clear_timers()

    engine:shuttle(1)
    pump_tick() -- tick 1: frame 99, within threshold → pre-buffers clip_b

    local video_count_before = #video_pre_buffer_calls
    assert(video_count_before > 0, "Should pre-buffer clip_b near boundary")

    pump_tick() -- tick 2: frame 100 → now IN clip_b

    -- After entering clip_b, approaching clip_b's end (frame 200) at frame 100
    -- Distance = 100 frames = 4.17s, outside 1s threshold → no pre-buffer
    -- The pre-buffer state for clip_b should have been consumed/reset
    -- No new pre-buffer call expected (too far from clip_b's end)
    assert(#video_pre_buffer_calls == video_count_before, string.format(
        "After entering clip_b, no new pre-buffer expected (far from clip_b end), got %d",
        #video_pre_buffer_calls))

    engine:stop()
    clear_timers()
    print("  pre-buffer resets on clip change passed")
end

print("\n✅ test_engine_lookahead.lua passed")
