-- Black-box test: PlaybackEngine video display contract.
--
-- Observable output = the surface. After load_sequence, the surface must
-- have a non-nil, non-black frame. After seek to a different position,
-- the surface frame must change. During play, the surface must receive
-- distinct advancing frames.
--
-- on_show_frame wires through to EMP.SURFACE_SET_FRAME exactly like the
-- real SequenceMonitor does. C++ PLAYBACK mock SEEK models the real
-- PlaybackController::Seek which synchronously delivers a frame to the
-- surface (deliverFrame with synchronous=true).
--
-- The test never inspects internal call sequences — only surface state.

require("test_env")

--------------------------------------------------------------------------------
-- Mock surface: the ONLY thing we inspect
--------------------------------------------------------------------------------

local BLACK_FRAME = "BLACK"  -- sentinel for gap/clear

local function make_surface()
    return {
        _frame = nil,          -- last frame set (nil = never set)
        _frame_count = 0,      -- total setFrame calls
        _history = {},          -- ordered list of frames set
    }
end

local controller_enabled = false

--------------------------------------------------------------------------------
-- Stubs
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(_, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

-- PlaybackController per-instance state (models C++ member variables)
local pc_surface = nil  -- surface set via SET_SURFACE

local qt_constants_mock
qt_constants_mock = {
    EMP = {
        SET_DECODE_MODE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function() end,
        TMB_SET_PLAYHEAD = function() end,
        TMB_GET_VIDEO_FRAME = function() return nil, { offline = false } end,

        -- The observable: frame reaches the surface
        SURFACE_SET_FRAME = function(surface, frame_handle)
            assert(surface, "SURFACE_SET_FRAME: surface is nil")
            surface._frame = frame_handle
            surface._frame_count = surface._frame_count + 1
            surface._history[#surface._history + 1] = frame_handle
        end,
    },
    PLAYBACK = {
        CREATE = function()
            if not controller_enabled then return nil end
            pc_surface = nil  -- fresh controller state
            return "mock_controller"
        end,
        CLOSE = function() pc_surface = nil end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_VIDEO_TRACKS = function() end,
        SET_SURFACE = function(_pc, surface)
            pc_surface = surface
        end,
        SET_CLIP_WINDOW = function() end,
        SET_NEED_CLIPS_CALLBACK = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        SET_SHUTTLE_MODE = function() end,
        STOP = function() end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        HAS_AUDIO = function() return false end,

        -- SEEK: models fixed C++ Seek → deliverFrame(frame, synchronous=true).
        -- Gets frame from Renderer mock and pushes to surface synchronously.
        SEEK = function(_pc, frame)
            if not pc_surface then return end
            local renderer = package.loaded["core.renderer"]
            local fh = renderer.get_video_frame(nil, nil, frame)
            if fh then
                qt_constants_mock.EMP.SURFACE_SET_FRAME(pc_surface, fh)
            else
                qt_constants_mock.EMP.SURFACE_SET_FRAME(pc_surface, BLACK_FRAME)
            end
        end,

        -- PLAY: no-op. C++ starts CVDisplayLink (no tick in unit test).
        PLAY = function() end,
    },
}

package.loaded["core.qt_constants"] = qt_constants_mock

package.loaded["core.logger"] = {
    debug = function() end, info = function() end,
    warn = function() end, error = function() end, trace = function() end,
}

package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 24, fps_den = 1,
            kind = "timeline", name = "Test",
            audio_sample_rate = 48000,
        }
    end,
    -- Returns distinct non-nil frame handles for each frame position.
    -- frame_handle encodes the frame number so we can verify frames change.
    get_video_frame = function(_tmb, _track_indices, frame)
        if frame >= 0 and frame < 200 then
            return "frame_" .. frame, {
                clip_id = "clip1", media_path = "/test.mov",
                source_frame = frame, rotation = 0,
                par_num = 1, par_den = 1,
                offline = false, pending = false,
            }
        end
        return nil, nil
    end,
}

local mock_clip_entry = {
    clip = {
        id = "clip1", timeline_start = 0, duration = 200, source_in = 0,
        rate = { fps_numerator = 24, fps_denominator = 1 },
    },
    track = { id = "track_0", track_index = 0, volume = 1.0, muted = false, soloed = false },
    media_path = "/test.mov",
    media_fps_num = 24, media_fps_den = 1,
}
package.loaded["models.sequence"] = {
    load = function()
        return {
            id = "seq1",
            compute_content_end = function() return 200 end,
            get_video_at = function(_, frame)
                if frame >= 0 and frame < 200 then return { mock_clip_entry } end
                return {}
            end,
            get_next_video = function() return {} end,
            get_prev_video = function() return {} end,
            get_audio_at = function() return {} end,
            get_next_audio = function() return {} end,
            get_prev_audio = function() return {} end,
        }
    end,
}

package.loaded["core.signals"] = {
    connect = function() return "conn" end,
    disconnect = function() end,
    emit = function() end,
}

local mock_audio = {
    session_initialized = true, playing = false, has_audio = false,
    max_media_time_us = 10000000, session_sample_rate = 48000,
    session_channels = 2, aop = "aop", sse = "sse", _time_us = 0,
}
mock_audio.is_ready = function() return true end
mock_audio.get_time_us = function() return mock_audio._time_us end
mock_audio.get_media_time_us = function() return mock_audio._time_us end
mock_audio.seek = function() end
mock_audio.start = function() mock_audio.playing = true end
mock_audio.stop = function() mock_audio.playing = false end
mock_audio.set_speed = function() end
mock_audio.set_max_time = function() end
mock_audio.apply_mix = function() end
mock_audio.refresh_mix_volumes = function() end
mock_audio.latch = function() end
mock_audio.play_burst = function() end
mock_audio.init_session = function() end
mock_audio.shutdown_session = function() end

--------------------------------------------------------------------------------
-- Load engine
--------------------------------------------------------------------------------

local PlaybackEngine = require("core.playback.playback_engine")
PlaybackEngine.init_audio(mock_audio)

--- Create engine wired like real SequenceMonitor:
-- on_show_frame → SURFACE_SET_FRAME(surface, fh)
-- set_surface called before load_sequence
local function make_engine()
    local surface = make_surface()

    local engine = PlaybackEngine.new({
        on_show_frame = function(fh, _meta)
            -- Mirrors SequenceMonitor:_on_show_frame exactly
            qt_constants_mock.EMP.SURFACE_SET_FRAME(surface, fh)
        end,
        on_show_gap = function()
            qt_constants_mock.EMP.SURFACE_SET_FRAME(surface, BLACK_FRAME)
        end,
        on_set_rotation = function() end,
        on_set_par = function() end,
        on_position_changed = function() end,
    })

    -- Real app: SequenceMonitor._create_widgets() calls set_surface before load
    engine:set_surface(surface)

    return engine, surface
end

local function drain_timers()
    local cbs = timer_callbacks
    timer_callbacks = {}
    for _, cb in ipairs(cbs) do cb() end
end

print("=== test_playback_video_display.lua ===")

--------------------------------------------------------------------------------
-- 1. Park: caller seeks after load_sequence → surface has non-black frame.
-- Engine's load_sequence sets up infrastructure; caller (SequenceMonitor)
-- is responsible for initial seek to saved_playhead from DB.
--------------------------------------------------------------------------------
print("\n--- 1. seek after load_sequence: surface has non-black frame (parked still) ---")
do
    controller_enabled = false
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 200)
    engine:seek(0)  -- caller's responsibility

    assert(surface._frame ~= nil,
        "surface._frame is nil after seek — no frame delivered")
    assert(surface._frame ~= BLACK_FRAME,
        "surface has BLACK frame after seek — should be a real frame")
    print("  PASS: Lua path")
end
do
    controller_enabled = true
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 200)
    engine:seek(0)  -- caller's responsibility

    assert(surface._frame ~= nil,
        "surface._frame is nil after seek (C++ path) — no frame delivered")
    assert(surface._frame ~= BLACK_FRAME,
        "surface has BLACK frame after seek (C++ path) — should be a real frame")
    print("  PASS: C++ path")
end

--------------------------------------------------------------------------------
-- 2. Seek: surface frame must change to the new position
--------------------------------------------------------------------------------
print("\n--- 2. seek: surface frame changes ---")
do
    controller_enabled = false
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 200)
    engine:seek(0)  -- initial park
    local parked_frame = surface._frame

    engine:seek(50)

    assert(surface._frame ~= nil,
        "surface._frame is nil after seek(50)")
    assert(surface._frame ~= BLACK_FRAME,
        "surface has BLACK frame after seek(50)")
    assert(surface._frame ~= parked_frame, string.format(
        "surface frame must change after seek: was %s, still %s",
        tostring(parked_frame), tostring(surface._frame)))
    print("  PASS: Lua path")
end
do
    controller_enabled = true
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 200)
    engine:seek(0)  -- initial park
    local parked_frame = surface._frame

    engine:seek(50)

    assert(surface._frame ~= nil,
        "surface._frame is nil after seek(50) (C++ path)")
    assert(surface._frame ~= BLACK_FRAME,
        "surface has BLACK frame after seek(50) (C++ path)")
    assert(surface._frame ~= parked_frame, string.format(
        "surface frame must change after seek (C++ path): was %s, still %s",
        tostring(parked_frame), tostring(surface._frame)))
    print("  PASS: C++ path")
end

--------------------------------------------------------------------------------
-- 3. Play: surface receives distinct advancing frames
--------------------------------------------------------------------------------
print("\n--- 3. play: surface shows advancing frames ---")
do
    controller_enabled = false
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 200)
    engine:seek(0)  -- initial park
    local before_count = surface._frame_count

    engine:play()
    for i = 1, 10 do
        mock_audio._time_us = i * 41667  -- ~24fps
        drain_timers()
    end
    engine:stop()

    local play_deliveries = surface._frame_count - before_count
    assert(play_deliveries >= 2, string.format(
        "surface must receive multiple frames during play, got %d", play_deliveries))

    -- Verify frames advanced (not the same frame repeated)
    local seen = {}
    local distinct = 0
    for i = before_count + 1, #surface._history do
        local f = surface._history[i]
        if f ~= BLACK_FRAME and not seen[f] then
            seen[f] = true
            distinct = distinct + 1
        end
    end
    assert(distinct >= 2, string.format(
        "surface must show distinct frames during play, got %d distinct", distinct))
    print("  PASS: Lua path")
end

--------------------------------------------------------------------------------
-- 4. Seek into gap: surface shows black (not stale frame)
--------------------------------------------------------------------------------
print("\n--- 4. seek into gap: surface shows black ---")
do
    controller_enabled = false
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 200)

    -- Seek beyond clip range (frame 200+ is a gap in mock)
    engine:seek(250)

    assert(surface._frame == BLACK_FRAME, string.format(
        "surface must show BLACK in gap, got %s", tostring(surface._frame)))
    print("  PASS: Lua path")
end
do
    controller_enabled = true
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 200)

    engine:seek(250)  -- gap frame

    assert(surface._frame == BLACK_FRAME, string.format(
        "surface must show BLACK in gap (C++ path), got %s", tostring(surface._frame)))
    print("  PASS: C++ path")
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print("\n✅ test_playback_video_display.lua passed")
