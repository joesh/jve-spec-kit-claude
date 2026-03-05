-- NSF test: PlaybackEngine audio transport guards when C++ controller active.
--
-- Verifies that Lua-side audio transport (_start_audio, _stop_audio, _sync_audio)
-- becomes a no-op when self._playback_controller exists, since C++ owns audio
-- transport (Flush/Reset/SetTarget/Start/Stop) via Play/Stop/SetSpeed.
--
-- Also tests:
-- - Clip window = union of loaded clips (prevents NeedClips spam)
-- - Shuttle unlatch doesn't call audio_playback when controller active
-- - seek() stopped doesn't call audio_playback.seek when controller active

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

-- Track PLAYBACK calls from playback_engine
local playback_calls = {}
local function reset_playback_calls() playback_calls = {} end
local function track_playback(name, ...)
    playback_calls[#playback_calls + 1] = { name = name, args = {...} }
end

local function find_call(name)
    for _, c in ipairs(playback_calls) do
        if c.name == name then return c end
    end
    return nil
end

-- TMB clip tracking: records what clips were set per track
local tmb_clips_set = {}
local function reset_tmb_clips() tmb_clips_set = {} end

-- Mock qt_constants with PLAYBACK namespace
package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function(tmb, media_type, track_idx, clips)
            tmb_clips_set[#tmb_clips_set + 1] = {
                media_type = media_type,
                track_idx = track_idx,
                clips = clips,
            }
        end,
        TMB_SET_PLAYHEAD = function() end,
        TMB_GET_VIDEO_FRAME = function() return nil, { offline = false } end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_controller" end,
        CLOSE = function(pc) track_playback("CLOSE", pc) end,
        SET_TMB = function(pc, tmb) track_playback("SET_TMB", pc, tmb) end,
        SET_BOUNDS = function(pc, tf, fn, fd)
            track_playback("SET_BOUNDS", pc, tf, fn, fd)
        end,
        SET_SURFACE = function(pc, s) track_playback("SET_SURFACE", pc, s) end,
        SET_CLIP_PROVIDER = function(pc, fn)
            track_playback("SET_CLIP_PROVIDER", pc, fn)
        end,
        RELOAD_ALL_CLIPS = function(pc)
            track_playback("RELOAD_ALL_CLIPS", pc)
        end,
        SET_POSITION_CALLBACK = function(pc, fn)
            track_playback("SET_POSITION_CALLBACK", pc, fn)
        end,
        SET_CLIP_TRANSITION_CALLBACK = function(pc, fn)
            track_playback("SET_CLIP_TRANSITION_CALLBACK", pc, fn)
        end,
        SET_SHUTTLE_MODE = function(pc, enabled)
            track_playback("SET_SHUTTLE_MODE", pc, enabled)
        end,
        PLAY = function(pc, dir, speed) track_playback("PLAY", pc, dir, speed) end,
        STOP = function(pc) track_playback("STOP", pc) end,
        PARK = function(pc, frame) track_playback("PARK", pc, frame) end,
        SEEK = function(pc, frame) track_playback("SEEK", pc, frame) end,
        ACTIVATE_AUDIO = function(pc, aop, sse, sr, ch)
            track_playback("ACTIVATE_AUDIO", pc, aop, sse, sr, ch)
        end,
        DEACTIVATE_AUDIO = function(pc) track_playback("DEACTIVATE_AUDIO", pc) end,
        HAS_AUDIO = function(pc) return false end,
    },
}

package.loaded["core.logger"] = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
    for_area = function() return { event = function() end, detail = function() end, warn = function() end, error = function() end } end,
}

-- Mock Renderer
package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 24, fps_den = 1,
            kind = "timeline", name = "Test Seq",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function(tmb, track_indices, frame)
        if frame >= 0 and frame < 100 then
            return "frame_handle", {
                clip_id = "clip1", media_path = "/test.mov",
                source_frame = frame, rotation = 0,
                par_num = 1, par_den = 1,
                offline = false,
            }
        end
        return nil, nil
    end,
}

-- Configurable mock sequence (returns real clip entries for window tests)
local mock_video_entries = {}
local mock_next_video_entries = {}
local mock_audio_entries = {}
local mock_next_audio_entries = {}

local mock_sequence = {
    id = "seq1",
    compute_content_end = function() return 200 end,
    get_video_at = function(self, frame) return mock_video_entries end,
    get_next_video = function(self, boundary) return mock_next_video_entries end,
    get_prev_video = function() return {} end,
    get_audio_at = function(self, frame) return mock_audio_entries end,
    get_next_audio = function(self, boundary) return mock_next_audio_entries end,
    get_prev_audio = function() return {} end,
    get_video_in_range = function() return {} end,
    get_audio_in_range = function() return {} end,
    get_track_indices = function() return { 0 } end,
}
package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

-- Tracked audio_playback mock
local audio_calls = {}
local function reset_audio_calls() audio_calls = {} end
local function track_audio(name, ...)
    audio_calls[#audio_calls + 1] = { name = name, args = {...} }
end
local function find_audio_call(name)
    for _, c in ipairs(audio_calls) do
        if c.name == name then return c end
    end
    return nil
end

local mock_audio = {
    session_initialized = true,
    playing = false,
    has_audio = true,
    max_media_time_us = 10000000,
    session_sample_rate = 48000,
    session_channels = 2,
    aop = "mock_aop",
    sse = "mock_sse",
    _time_us = 0,
}
-- Methods defined after table exists (closures reference local mock_audio)
mock_audio.is_ready = function() return true end
mock_audio.get_time_us = function() return mock_audio._time_us end
mock_audio.get_media_time_us = function() return mock_audio._time_us end
mock_audio.seek = function(t) track_audio("seek", t) end
mock_audio.start = function() track_audio("start"); mock_audio.playing = true end
mock_audio.stop = function() track_audio("stop"); mock_audio.playing = false end
mock_audio.set_speed = function(s) track_audio("set_speed", s) end
mock_audio.set_max_time = function(t) track_audio("set_max_time", t) end
mock_audio.apply_mix = function(tmb, mix_params, edit_time_us)
    track_audio("apply_mix")
    mock_audio.has_audio = true
end
mock_audio.refresh_mix_volumes = function() end
mock_audio.latch = function(t) track_audio("latch", t) end
mock_audio.play_burst = function(t, d) track_audio("play_burst", t, d) end
mock_audio.init_session = function() end
mock_audio.shutdown_session = function() end

-- Mock signals
package.loaded["core.signals"] = {
    connect = function() return "conn_id" end,
    disconnect = function() end,
    emit = function() end,
}

--------------------------------------------------------------------------------
-- Load PlaybackEngine
--------------------------------------------------------------------------------
local PlaybackEngine = require("core.playback.playback_engine")

-- Wire audio module
PlaybackEngine.init_audio(mock_audio)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function make_engine()
    local log = { positions = {} }
    local engine = PlaybackEngine.new({
        on_show_frame = function() end,
        on_show_gap = function() end,
        on_set_rotation = function() end,
        on_set_par = function() end,
        on_position_changed = function(frame) log.positions[#log.positions + 1] = frame end,
    })
    return engine, log
end

--- Create engine with sequence loaded + C++ controller active.
local function make_engine_with_controller()
    local engine = make_engine()
    mock_video_entries = {}
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}
    timer_callbacks = {}

    engine:load_sequence("seq1", 200)
    -- _setup_playback_controller creates the C++ controller via PLAYBACK.CREATE
    assert(engine._playback_controller, "controller should be created")

    -- Reset tracking AFTER load (load_sequence sets up infrastructure)
    reset_playback_calls()
    reset_audio_calls()
    reset_tmb_clips()
    timer_callbacks = {}
    return engine
end

print("=== test_playback_controller_audio_guards.lua ===")

--------------------------------------------------------------------------------
-- 1. _start_audio is no-op when controller active
--------------------------------------------------------------------------------
print("\n--- 1. _start_audio no-op when controller active ---")
do
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    engine.direction = 1
    engine.speed = 1
    reset_audio_calls()

    engine:_start_audio()

    assert(not find_audio_call("seek"),
        "_start_audio must NOT call audio_playback.seek when controller active")
    assert(not find_audio_call("start"),
        "_start_audio must NOT call audio_playback.start when controller active")
    print("  PASS: _start_audio is no-op with controller")
end

--------------------------------------------------------------------------------
-- 2. _stop_audio is no-op when controller active
--------------------------------------------------------------------------------
print("\n--- 2. _stop_audio no-op when controller active ---")
do
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    mock_audio.playing = true
    reset_audio_calls()

    engine:_stop_audio()

    assert(not find_audio_call("stop"),
        "_stop_audio must NOT call audio_playback.stop when controller active")
    print("  PASS: _stop_audio is no-op with controller")
    mock_audio.playing = false
end

--------------------------------------------------------------------------------
-- 3. _sync_audio is no-op when controller active
--------------------------------------------------------------------------------
print("\n--- 3. _sync_audio no-op when controller active ---")
do
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    engine.direction = 1
    engine.speed = 2
    reset_audio_calls()

    engine:_sync_audio()

    assert(not find_audio_call("set_speed"),
        "_sync_audio must NOT call audio_playback.set_speed when controller active")
    print("  PASS: _sync_audio is no-op with controller")
end

--------------------------------------------------------------------------------
-- 4. Shuttle unlatch: no audio_playback calls when controller active
--------------------------------------------------------------------------------
print("\n--- 4. shuttle unlatch skips audio when controller active ---")
do
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    engine.state = "playing"
    engine.transport_mode = "shuttle"
    engine.direction = 1
    engine.speed = 1
    engine.latched = true
    engine.latched_boundary = "end"
    engine._position = 199
    reset_audio_calls()
    reset_playback_calls()

    -- Shuttle reverse to unlatch
    engine:shuttle(-1)

    -- Controller should get PLAY call (it handles audio transport)
    assert(find_call("PLAY"),
        "shuttle unlatch must call PLAYBACK.PLAY")

    -- Lua must NOT touch audio_playback directly
    assert(not find_audio_call("seek"),
        "shuttle unlatch must NOT call audio_playback.seek when controller active")
    assert(not find_audio_call("start"),
        "shuttle unlatch must NOT call audio_playback.start when controller active")
    assert(not find_audio_call("set_speed"),
        "shuttle unlatch must NOT call audio_playback.set_speed when controller active")
    print("  PASS: shuttle unlatch delegates to C++, no direct audio calls")
end

--------------------------------------------------------------------------------
-- 5. seek() stopped: no audio_playback.seek when controller active
--------------------------------------------------------------------------------
print("\n--- 5. seek() stopped skips audio_playback.seek when controller active ---")
do
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    engine.state = "stopped"
    engine.direction = 0
    reset_audio_calls()

    engine:seek(50)

    -- apply_mix may be called (mix params update is needed regardless)
    -- But audio_playback.seek must NOT be called for stopped state
    assert(not find_audio_call("seek"),
        "seek() stopped must NOT call audio_playback.seek when controller active")
    -- Controller should get PARK call (seek uses PARK + Lua pull)
    assert(find_call("PARK"),
        "seek() must delegate to PLAYBACK.PARK")
    print("  PASS: seek stopped delegates to C++, no audio_playback.seek")
end

--------------------------------------------------------------------------------
-- 6. notify_content_changed calls RELOAD_ALL_CLIPS
--------------------------------------------------------------------------------
print("\n--- 6. notify_content_changed calls RELOAD_ALL_CLIPS ---")
do
    local engine = make_engine_with_controller()

    reset_playback_calls()
    engine:notify_content_changed()

    assert(find_call("RELOAD_ALL_CLIPS"),
        "notify_content_changed must call PLAYBACK.RELOAD_ALL_CLIPS")
    print("  PASS: notify_content_changed calls RELOAD_ALL_CLIPS")
end

--------------------------------------------------------------------------------
-- 9. No audio_playback calls during play() when controller active
--------------------------------------------------------------------------------
print("\n--- 9. play() delegates to controller, no audio_playback.start ---")
do
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    reset_audio_calls()
    reset_playback_calls()

    engine:play()

    -- Controller should get PLAY call
    assert(find_call("PLAY"),
        "play() must call PLAYBACK.PLAY")

    -- Lua must NOT start audio directly
    assert(not find_audio_call("start"),
        "play() must NOT call audio_playback.start when controller active")
    assert(not find_audio_call("seek"),
        "play() must NOT call audio_playback.seek when controller active")
    print("  PASS: play() uses controller, no direct audio calls")
end

--------------------------------------------------------------------------------
-- 10. load_sequence uses SET_CLIP_PROVIDER (not SET_NEED_CLIPS_CALLBACK)
--------------------------------------------------------------------------------
print("\n--- 10. load_sequence wires SET_CLIP_PROVIDER ---")
do
    mock_video_entries = {}
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}

    local engine = make_engine()
    reset_playback_calls()
    engine:load_sequence("seq1", 200)

    assert(find_call("SET_CLIP_PROVIDER"),
        "load_sequence must call SET_CLIP_PROVIDER")
    print("  PASS: load_sequence wires SET_CLIP_PROVIDER")
end

--------------------------------------------------------------------------------
-- 14. Without controller, _start_audio DOES call audio_playback
--------------------------------------------------------------------------------
print("\n--- 14. _start_audio works normally without controller ---")
do
    local engine = make_engine()
    -- Load but remove controller
    mock_video_entries = {}
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}
    engine:load_sequence("seq1", 200)
    engine._playback_controller = nil  -- simulate no C++ controller

    engine._audio_owner = true
    engine.direction = 1
    engine.speed = 1
    engine.fps_num = 24
    engine.fps_den = 1
    reset_audio_calls()

    engine:_start_audio()

    -- Without controller, audio_playback.seek and start should be called
    assert(find_audio_call("seek"),
        "_start_audio must call audio_playback.seek when no controller")
    assert(find_audio_call("start"),
        "_start_audio must call audio_playback.start when no controller")
    print("  PASS: _start_audio works normally without controller")
end


--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print("\n✅ test_playback_controller_audio_guards.lua passed")
