#!/usr/bin/env luajit
--- Test: PlaybackEngine lookahead pre-buffers next clip near edit points.
--
-- Video pre-buffer: handled internally by TMB (SetPlayhead triggers worker pool).
-- Audio lookahead: 2-second threshold before clip_end_us (Lua-side, kept until Phase 3c).
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
local audio_pre_buffer_calls = {}
local tmb_set_playhead_calls = {}
local function reset_logs()
    audio_pre_buffer_calls = {}
    tmb_set_playhead_calls = {}
end

-- Mock TMB handle
local mock_tmb = "mock_tmb_handle"

package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        TMB_CREATE = function() return mock_tmb end,
        TMB_CLOSE = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function() end,
        TMB_SET_PLAYHEAD = function(tmb, frame, dir, speed)
            tmb_set_playhead_calls[#tmb_set_playhead_calls + 1] = {
                frame = frame, dir = dir, speed = speed,
            }
        end,
        TMB_GET_VIDEO_FRAME = function(tmb, track_id, frame)
            -- Return metadata matching the clip at this position
            if frame >= 0 and frame < 100 then
                return "frame_" .. frame, {
                    clip_id = "clip_a", media_path = "/clip_a.mov",
                    source_frame = frame, rotation = 0,
                    clip_fps_num = 24, clip_fps_den = 1,
                    clip_end_frame = 100, clip_start_frame = 0,
                    offline = false,
                }
            elseif frame >= 100 and frame < 200 then
                return "frame_" .. frame, {
                    clip_id = "clip_b", media_path = "/clip_b.mov",
                    source_frame = frame - 100, rotation = 0,
                    clip_fps_num = 24, clip_fps_den = 1,
                    clip_end_frame = 200, clip_start_frame = 100,
                    offline = false,
                }
            end
            -- Gap: return nil frame but still need metadata for the function
            return nil, { clip_id = "", offline = false }
        end,
    },
}

package.loaded["core.media.media_cache"] = {
    ensure_audio_pooled = function()
        return { has_audio = true, audio_sample_rate = 48000 }
    end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
}

-- Offline frame cache mock (not used in these tests)
package.loaded["core.media.offline_frame_cache"] = {
    get_frame = function() return nil end,
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
    frame_rate = { fps_numerator = 24, fps_denominator = 1 },
    width = 1920, height = 1080,
    name = "TestSeq", kind = "timeline",
    audio_sample_rate = 48000,
    compute_content_end = function() return 200 end,
    get_video_at = function(self, frame)
        if frame >= 0 and frame < 100 then
            return {{
                media_path = "/clip_a.mov",
                source_frame = frame,
                clip = {
                    id = "clip_a",
                    rate = { fps_numerator = 24, fps_denominator = 1 },
                    timeline_start = 0, duration = 100, source_in = 0,
                },
                track = { id = "track_v1", track_index = 1 },
            }}
        elseif frame >= 100 and frame < 200 then
            return {{
                media_path = "/clip_b.mov",
                source_frame = frame - 100,
                clip = {
                    id = "clip_b",
                    rate = { fps_numerator = 24, fps_denominator = 1 },
                    timeline_start = 100, duration = 100, source_in = 0,
                },
                track = { id = "track_v1", track_index = 1 },
            }}
        end
        return {}
    end,
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
                track = { id = "track_v1", track_index = 1 },
            }}
        end
        return {}
    end,
    get_prev_video = function(self, before_frame)
        if before_frame == 0 then
            return {}
        end
        if before_frame == 100 then
            return {{
                media_path = "/clip_a.mov",
                source_frame = 99,
                clip = {
                    id = "clip_a",
                    rate = { fps_numerator = 24, fps_denominator = 1 },
                    timeline_start = 0, duration = 100, source_in = 0,
                },
                track = { id = "track_v1", track_index = 1 },
            }}
        end
        return {}
    end,
    get_audio_at = function() return {} end,
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
                    source_in = 0,
                },
                track = { id = "track_a1", track_index = 1, muted = false, soloed = false, volume = 1.0 },
                media_fps_num = 48000,
                media_fps_den = 1,
            }}
        end
        return {}
    end,
    get_prev_audio = function() return {} end,
}

package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

-- Renderer uses TMB-based signature: get_video_frame(tmb, track_indices, frame)
-- The actual renderer module will be loaded from the real code (it calls TMB_GET_VIDEO_FRAME)

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
-- Test 1: TMB SetPlayhead called during playback (video pre-buffer is TMB-internal)
--------------------------------------------------------------------------------

print("\n--- TMB SetPlayhead called during forward playback ---")
do
    local engine = make_engine()
    reset_logs()

    engine:seek(90)
    clear_timers()

    engine:shuttle(1)
    pump_tick() -- frame-based advance: 90 -> 91

    assert(#tmb_set_playhead_calls > 0, string.format(
        "Expected TMB_SET_PLAYHEAD call during playback, got %d calls",
        #tmb_set_playhead_calls))
    assert(tmb_set_playhead_calls[1].dir == 1,
        "SetPlayhead direction should be 1 (forward)")

    engine:stop()
    clear_timers()
    print("  TMB SetPlayhead called during forward playback passed")
end

-- Tests 2-5 (audio lookahead pre-buffer) deleted in Phase 3c:
-- TMB handles audio pre-buffering internally via SetPlayhead + worker pool.

print("\n✅ test_engine_lookahead.lua passed")
