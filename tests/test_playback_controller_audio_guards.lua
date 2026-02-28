-- NSF test: PlaybackEngine audio transport guards when C++ controller active.
--
-- Verifies that Lua-side audio transport (_start_audio, _stop_audio, _sync_audio)
-- becomes a no-op when self._playback_controller exists, since C++ owns audio
-- transport (Flush/Reset/SetTarget/Start/Stop) via Play/Stop/SetSpeed.
--
-- Also tests:
-- - Clip window = union of loaded clips (prevents NeedClips spam)
-- - _send_clips_to_tmb propagates SET_VIDEO_TRACKS to C++ controller
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
        SET_VIDEO_TRACKS = function(pc, indices)
            track_playback("SET_VIDEO_TRACKS", pc, indices)
        end,
        SET_SURFACE = function(pc, s) track_playback("SET_SURFACE", pc, s) end,
        SET_CLIP_WINDOW = function(pc, type, lo, hi)
            track_playback("SET_CLIP_WINDOW", pc, type, lo, hi)
        end,
        SET_NEED_CLIPS_CALLBACK = function(pc, fn)
            track_playback("SET_NEED_CLIPS_CALLBACK", pc, fn)
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

--- Build a mock video entry (matches Sequence:get_video_at return format).
local function make_video_entry(clip_id, track_idx, tl_start, duration, source_in)
    local si = source_in or 0
    return {
        clip = {
            id = clip_id,
            timeline_start = tl_start,
            duration = duration,
            source_in = si,
            source_out = si + duration,
            rate = { fps_numerator = 24, fps_denominator = 1 },
        },
        track = { id = "track_" .. track_idx, track_index = track_idx },
        media_path = "/test.mov",
        media_fps_num = 24,
        media_fps_den = 1,
    }
end

--- Build a mock audio entry.
local function make_audio_entry(clip_id, track_idx, tl_start, duration, source_in)
    local entry = make_video_entry(clip_id, track_idx, tl_start, duration, source_in)
    entry.track.volume = 1.0
    entry.track.muted = false
    entry.track.soloed = false
    return entry
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
    -- Controller should get SEEK call
    assert(find_call("SEEK"),
        "seek() must delegate to PLAYBACK.SEEK")
    print("  PASS: seek stopped delegates to C++, no audio_playback.seek")
end

--------------------------------------------------------------------------------
-- 6. Clip window = union of loaded clips (not intersection of current)
--------------------------------------------------------------------------------
print("\n--- 6. clip window is union of all loaded clips ---")
do
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    engine.direction = 1

    -- Set up: current clip [100, 200), next clip [200, 500)
    mock_video_entries = {
        make_video_entry("clip_A", 0, 100, 100, 0),  -- [100, 200)
    }
    mock_next_video_entries = {
        make_video_entry("clip_B", 0, 200, 300, 0),  -- [200, 500)
    }
    mock_audio_entries = {}
    mock_next_audio_entries = {}

    reset_playback_calls()
    engine:_send_video_clips_to_tmb(150)

    -- Find SET_CLIP_WINDOW call for video
    local window_call = nil
    for _, c in ipairs(playback_calls) do
        if c.name == "SET_CLIP_WINDOW" and c.args[2] == "video" then
            window_call = c
        end
    end

    assert(window_call, "SET_CLIP_WINDOW must be called for video")
    local lo = window_call.args[3]
    local hi = window_call.args[4]

    -- Union should be [100, 500), NOT intersection [100, 200)
    assert(lo == 100, string.format(
        "clip window lo must be 100 (union start), got %s", tostring(lo)))
    assert(hi == 500, string.format(
        "clip window hi must be 500 (union end), got %s", tostring(hi)))
    print("  PASS: video clip window is union [100, 500)")
end

do
    -- Same test for audio clips
    local engine = make_engine_with_controller()
    engine._audio_owner = true
    engine.direction = 1

    -- Current audio clip [50, 150), next [150, 400)
    mock_audio_entries = {
        make_audio_entry("aclip_A", 0, 50, 100, 0),  -- [50, 150)
    }
    mock_next_audio_entries = {
        make_audio_entry("aclip_B", 0, 150, 250, 0),  -- [150, 400)
    }

    reset_playback_calls()
    engine:_send_audio_clips_only(100)

    local window_call = nil
    for _, c in ipairs(playback_calls) do
        if c.name == "SET_CLIP_WINDOW" and c.args[2] == "audio" then
            window_call = c
        end
    end

    assert(window_call, "SET_CLIP_WINDOW must be called for audio")
    local lo = window_call.args[3]
    local hi = window_call.args[4]

    assert(lo == 50, string.format(
        "audio clip window lo must be 50 (union start), got %s", tostring(lo)))
    assert(hi == 400, string.format(
        "audio clip window hi must be 400 (union end), got %s", tostring(hi)))
    print("  PASS: audio clip window is union [50, 400)")
end

--------------------------------------------------------------------------------
-- 7. _send_clips_to_tmb propagates SET_VIDEO_TRACKS to controller
--------------------------------------------------------------------------------
print("\n--- 7. _send_clips_to_tmb propagates SET_VIDEO_TRACKS ---")
do
    local engine = make_engine_with_controller()
    engine.direction = 1

    -- Set up: video clip on track 0
    mock_video_entries = {
        make_video_entry("clip_C", 0, 0, 100, 0),
    }
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}

    reset_playback_calls()
    engine:_send_clips_to_tmb(50)

    -- Verify SET_VIDEO_TRACKS was called
    local vt_call = find_call("SET_VIDEO_TRACKS")
    assert(vt_call, "_send_clips_to_tmb must call SET_VIDEO_TRACKS on controller")
    local indices = vt_call.args[2]
    assert(type(indices) == "table" and #indices == 1,
        "SET_VIDEO_TRACKS must include track index")
    assert(indices[1] == 0, string.format(
        "SET_VIDEO_TRACKS index must be 0, got %s", tostring(indices[1])))
    print("  PASS: _send_clips_to_tmb propagates video tracks to controller")
end

--------------------------------------------------------------------------------
-- 8. _send_clips_to_tmb window uses union (not intersection)
--------------------------------------------------------------------------------
print("\n--- 8. _send_clips_to_tmb window is union ---")
do
    local engine = make_engine_with_controller()
    engine.direction = 1

    -- Current video clip [100, 200), next [200, 400)
    mock_video_entries = {
        make_video_entry("clip_D", 0, 100, 100, 0),
    }
    mock_next_video_entries = {
        make_video_entry("clip_E", 0, 200, 200, 0),
    }
    mock_audio_entries = {}
    mock_next_audio_entries = {}

    engine._tmb_clip_window = nil  -- force re-query
    engine:_send_clips_to_tmb(150)

    -- _tmb_clip_window should be the union
    local w = engine._tmb_clip_window
    assert(w, "_tmb_clip_window must be set")
    assert(w.lo == 100, string.format(
        "Lua clip window lo must be 100, got %s", tostring(w.lo)))
    assert(w.hi == 400, string.format(
        "Lua clip window hi must be 400, got %s", tostring(w.hi)))
    print("  PASS: _send_clips_to_tmb window is union [100, 400)")
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
-- 10. Empty clip window: no SetClipWindow call (not degenerate window)
--------------------------------------------------------------------------------
print("\n--- 10. empty clips: no SetClipWindow ---")
do
    local engine = make_engine_with_controller()
    engine.direction = 1
    mock_video_entries = {}
    mock_next_video_entries = {}

    reset_playback_calls()
    engine:_send_video_clips_to_tmb(50)

    -- No clips → no SetClipWindow
    local window_call = nil
    for _, c in ipairs(playback_calls) do
        if c.name == "SET_CLIP_WINDOW" and c.args[2] == "video" then
            window_call = c
        end
    end
    assert(not window_call,
        "SET_CLIP_WINDOW must NOT be called when no clips loaded")
    print("  PASS: no SetClipWindow for empty clip set")
end

--------------------------------------------------------------------------------
-- 11. _send_clips_to_tmb window uses VIDEO clips only (not audio)
-- Audio clips may extend far beyond video, inflating the window and preventing
-- re-query when seeking to positions where TMB has no video data.
--------------------------------------------------------------------------------
print("\n--- 11. _send_clips_to_tmb window uses video clips only ---")
do
    local engine = make_engine_with_controller()
    engine.direction = 1

    -- Video clip [100, 200), audio clip [50, 300)
    -- Audio extends BEYOND video in both directions
    mock_video_entries = {
        make_video_entry("clip_V", 0, 100, 100, 0),  -- [100, 200)
    }
    mock_next_video_entries = {}
    mock_audio_entries = {
        make_audio_entry("clip_A", 0, 50, 250, 0),  -- [50, 300)
    }
    mock_next_audio_entries = {}

    engine._tmb_clip_window = nil  -- force re-query
    engine:_send_clips_to_tmb(150)

    -- Window must be VIDEO-only: [100, 200), NOT [50, 300)
    local w = engine._tmb_clip_window
    assert(w, "_tmb_clip_window must be set (video clips present)")
    assert(w.lo == 100, string.format(
        "_send_clips_to_tmb window lo must be video start 100, got %s", tostring(w.lo)))
    assert(w.hi == 200, string.format(
        "_send_clips_to_tmb window hi must be video end 200, got %s", tostring(w.hi)))
    print("  PASS: window bounded by video clips only (audio excluded)")
end

--------------------------------------------------------------------------------
-- 12. load_sequence creates controller with empty tracks (first seek populates)
--------------------------------------------------------------------------------
print("\n--- 12. load_sequence ordering: tracks before controller ---")
do
    -- Reset state
    mock_video_entries = {
        make_video_entry("clip_load", 0, 0, 100, 0),
    }
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}
    reset_playback_calls()

    local engine = make_engine()
    engine:load_sequence("seq1", 200)

    -- After load, controller should exist with empty tracks
    assert(engine._playback_controller, "controller must be created after load")
    local vt_call = find_call("SET_VIDEO_TRACKS")
    assert(vt_call, "SET_VIDEO_TRACKS must be called during load_sequence")
    local indices = vt_call.args[2]
    assert(#indices == 0,
        "SET_VIDEO_TRACKS must receive empty indices (populated by first seek, not load)")

    -- First seek should populate tracks
    reset_playback_calls()
    engine:seek(50)
    vt_call = find_call("SET_VIDEO_TRACKS")
    assert(vt_call, "SET_VIDEO_TRACKS must be called during first seek")
    indices = vt_call.args[2]
    assert(#indices > 0,
        "SET_VIDEO_TRACKS must receive non-empty indices after seek")
    print("  PASS: load_sequence creates controller, first seek populates tracks")
end

--------------------------------------------------------------------------------
-- 13. load_sequence does NOT send initial clip window (first seek does)
--------------------------------------------------------------------------------
print("\n--- 13. load_sequence sends no initial clip window ---")
do
    -- Set up clips
    mock_video_entries = {
        make_video_entry("clip_init", 0, 0, 100, 0),
    }
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}

    local engine = make_engine()
    reset_playback_calls()
    engine:load_sequence("seq1", 200)

    -- No SET_CLIP_WINDOW during load (no _send_clips_to_tmb(0) anymore)
    local any_clip_window = false
    for _, c in ipairs(playback_calls) do
        if c.name == "SET_CLIP_WINDOW" then any_clip_window = true end
    end
    assert(not any_clip_window,
        "load_sequence must NOT send clip window (first seek populates)")

    -- First seek should set clip window
    reset_playback_calls()
    engine:seek(50)
    local video_window = nil
    for _, c in ipairs(playback_calls) do
        if c.name == "SET_CLIP_WINDOW" and c.args[2] == "video" then
            video_window = c
        end
    end
    assert(video_window, "first seek must send video clip window")
    print("  PASS: no clip window at load, populated by first seek")
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
-- 15. Clip window boundary → gap (no next clips): _tmb_clip_window = nil
--------------------------------------------------------------------------------
print("\n--- 15. clip window boundary into gap: no crash, window cleared ---")
do
    local engine = make_engine_with_controller()
    engine.direction = 1

    -- First: load a clip [0, 100) → establishes a valid clip window
    mock_video_entries = {
        make_video_entry("clip_gap", 0, 0, 100, 0),
    }
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}

    engine._tmb_clip_window = nil  -- force re-query
    engine:_send_clips_to_tmb(50)
    assert(engine._tmb_clip_window, "clip window must be set after loading clip")
    assert(engine._tmb_clip_window.lo == 0, "window lo=0")
    assert(engine._tmb_clip_window.hi == 100, "window hi=100")

    -- Now: playhead exits clip window into gap (frame 150, no clips there)
    mock_video_entries = {}
    mock_next_video_entries = {}
    mock_audio_entries = {}
    mock_next_audio_entries = {}

    engine._tmb_clip_window = nil  -- force re-query
    engine:_send_clips_to_tmb(150)

    -- Gap: _tmb_clip_window should be nil (no clips found, force re-query next tick)
    assert(engine._tmb_clip_window == nil,
        "_tmb_clip_window must be nil when playhead is in gap (no clips loaded)")

    -- No crash, no SET_CLIP_WINDOW call for degenerate window
    reset_playback_calls()
    engine._tmb_clip_window = nil
    engine:_send_clips_to_tmb(150)
    local gap_window = nil
    for _, c in ipairs(playback_calls) do
        if c.name == "SET_CLIP_WINDOW" and c.args[2] == "video" then
            gap_window = c
        end
    end
    assert(not gap_window,
        "SET_CLIP_WINDOW must NOT be called when no clips in gap")
    print("  PASS: gap at sequence end: window cleared, no crash")
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print("\n✅ test_playback_controller_audio_guards.lua passed")
