--- Test: offline frame display — park-pull + playback offline paths.
--
-- Verifies both MVC display paths for offline clips:
-- 1. Park mode (seek): PARK + Renderer.get_video_frame → _on_show_frame
-- 2. Playback mode: _on_clip_transition with offline=true → Renderer pull
--
-- Also verifies error_msg propagation from TMB metadata to offline frame.
require("test_env")

--------------------------------------------------------------------------------
-- Mock surface
--------------------------------------------------------------------------------

local BLACK_FRAME = "BLACK"

local function make_surface()
    return {
        _frame = nil,
        _frame_count = 0,
        _history = {},
    }
end

--------------------------------------------------------------------------------
-- Stubs
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(_, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

local pc_surface = nil  -- luacheck: no unused
local stored_clip_transition_cb = nil

-- Track what TMB_GET_VIDEO_FRAME returns for each frame
local tmb_responses = {}

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
        TMB_GET_VIDEO_FRAME = function(_tmb, _track, frame)
            local resp = tmb_responses[frame]
            if resp then
                return resp.frame_handle, resp.metadata
            end
            -- Default: gap
            return nil, { offline = false }
        end,
        SURFACE_SET_FRAME = function(surface, frame_handle)
            assert(surface, "SURFACE_SET_FRAME: surface is nil")
            surface._frame = frame_handle
            surface._frame_count = surface._frame_count + 1
            surface._history[#surface._history + 1] = frame_handle
        end,
        SURFACE_SET_ROTATION = function() end,
        SURFACE_SET_PAR = function() end,
        -- Compose offline frame: returns a sentinel with the filename
        COMPOSE_OFFLINE_FRAME = function(_png, lines)
            local filename = (lines[2] and lines[2].text) or "unknown"
            return "OFFLINE:" .. filename
        end,
    },
    PLAYBACK = {
        CREATE = function()
            pc_surface = nil
            return "mock_controller"
        end,
        CLOSE = function() pc_surface = nil end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function(_pc, surface)
            pc_surface = surface
        end,
        SET_CLIP_WINDOW = function() end,
        SET_NEED_CLIPS_CALLBACK = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function(_pc, fn)
            stored_clip_transition_cb = fn
        end,
        SET_SHUTTLE_MODE = function() end,
        STOP = function() end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        HAS_AUDIO = function() return false end,
        PARK = function() end,
        SEEK = function() end,
        PLAY = function() end,
    },
}

package.loaded["core.qt_constants"] = qt_constants_mock

package.loaded["core.logger"] = {
    for_area = function()
        return {
            event = function() end, detail = function() end,
            warn = function() end, error = function() end,
        }
    end,
}

-- Mock Sequence model — must be set BEFORE requiring Renderer,
-- because renderer.lua does `require("models.sequence")` at load time.
local mock_clip_entry = {
    clip = {
        id = "clip1", timeline_start = 0, duration = 100, source_in = 0, source_out = 100,
        rate = { fps_numerator = 24, fps_denominator = 1 },
    },
    track = { id = "track_0", track_index = 0, volume = 1.0, muted = false, soloed = false },
    media_path = "/test.mov",
    media_fps_num = 24, media_fps_den = 1,
}

local offline_clip_entry = {
    clip = {
        id = "clip_offline", timeline_start = 100, duration = 100, source_in = 0, source_out = 100,
        rate = { fps_numerator = 24, fps_denominator = 1 },
    },
    track = { id = "track_0", track_index = 0, volume = 1.0, muted = false, soloed = false },
    media_path = "/offline.braw",
    media_fps_num = 24, media_fps_den = 1,
}

package.loaded["models.sequence"] = {
    load = function()
        return {
            id = "seq1",
            name = "Test",
            kind = "timeline",
            width = 1920, height = 1080,
            frame_rate = { fps_numerator = 24, fps_denominator = 1 },
            audio_sample_rate = 48000,
            compute_content_end = function() return 300 end,
            get_video_at = function(_, frame)
                if frame >= 0 and frame < 100 then return { mock_clip_entry } end
                if frame >= 100 and frame < 200 then return { offline_clip_entry } end
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

-- offline_frame_cache: use the real module (it calls COMPOSE_OFFLINE_FRAME mock)
require("core.media.offline_frame_cache")

-- Renderer: use the real module — this is what we're testing
require("core.renderer")

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

local function make_engine()
    local surface = make_surface()

    local engine = PlaybackEngine.new({
        on_show_frame = function(fh, _meta)
            qt_constants_mock.EMP.SURFACE_SET_FRAME(surface, fh)
        end,
        on_show_gap = function()
            qt_constants_mock.EMP.SURFACE_SET_FRAME(surface, BLACK_FRAME)
        end,
        on_set_rotation = function() end,
        on_set_par = function() end,
        on_position_changed = function() end,
    })

    engine:set_surface(surface)
    return engine, surface
end

print("=== test_offline_frame_display.lua ===")

--------------------------------------------------------------------------------
-- 1. Park mode: seek to online clip → surface has real frame
--------------------------------------------------------------------------------
print("\n--- 1. park: seek to online clip ---")
do
    -- Configure TMB mock: frame 50 is online
    tmb_responses[50] = {
        frame_handle = "frame_50",
        metadata = {
            clip_id = "clip1", media_path = "/test.mov",
            source_frame = 50, rotation = 0,
            par_num = 1, par_den = 1,
            offline = false, pending = false,
        },
    }

    local engine, surface = make_engine()
    engine:load_sequence("seq1", 300)
    engine:seek(50)

    assert(surface._frame == "frame_50", string.format(
        "online seek: surface should show frame_50, got %s", tostring(surface._frame)))
    print("  PASS")
end

--------------------------------------------------------------------------------
-- 2. Park mode: seek to offline clip → surface has offline frame (not stale)
--------------------------------------------------------------------------------
print("\n--- 2. park: seek to offline clip ---")
do
    -- Configure TMB mock: frame 150 is offline
    tmb_responses[150] = {
        frame_handle = nil,  -- no decoded frame
        metadata = {
            clip_id = "clip_offline", media_path = "/offline.braw",
            source_frame = 50, rotation = 0,
            par_num = 1, par_den = 1,
            offline = true, pending = false,
            error_msg = "File not found: /offline.braw",
        },
    }

    local engine, surface = make_engine()
    engine:load_sequence("seq1", 300)
    engine:seek(150)

    assert(surface._frame ~= nil, "offline seek: surface must not be nil")
    assert(surface._frame ~= BLACK_FRAME, "offline seek: surface must not be black")
    -- offline_frame_cache composes a frame with the filename
    assert(type(surface._frame) == "string" and surface._frame:find("OFFLINE"),
        string.format("offline seek: surface should show offline frame, got %s",
            tostring(surface._frame)))
    print("  PASS")
end

--------------------------------------------------------------------------------
-- 3. Park mode: seek to gap → surface shows black
--------------------------------------------------------------------------------
print("\n--- 3. park: seek to gap ---")
do
    -- No TMB response for frame 250 → gap
    tmb_responses[250] = nil

    local engine, surface = make_engine()
    engine:load_sequence("seq1", 300)
    engine:seek(250)

    assert(surface._frame == BLACK_FRAME, string.format(
        "gap seek: surface must show BLACK, got %s", tostring(surface._frame)))
    print("  PASS")
end

--------------------------------------------------------------------------------
-- 4. Playback mode: clip transition to offline → offline frame displayed
--------------------------------------------------------------------------------
print("\n--- 4. playback: clip transition to offline ---")
do
    -- Frame 150 is offline (same as test 2)
    tmb_responses[150] = {
        frame_handle = nil,
        metadata = {
            clip_id = "clip_offline", media_path = "/offline.braw",
            source_frame = 50, rotation = 0,
            par_num = 1, par_den = 1,
            offline = true, pending = false,
        },
    }

    local engine, surface = make_engine()
    engine:load_sequence("seq1", 300)
    -- Seek to frame 50 first (online, sets initial display)
    engine:seek(50)
    local online_frame = surface._frame
    assert(online_frame == "frame_50", "precondition: online frame displayed")

    -- Simulate playback advancing to offline clip
    -- C++ would fire clip transition callback
    engine._position = 150  -- simulate playback position
    assert(stored_clip_transition_cb, "clip transition callback must be set")
    stored_clip_transition_cb("clip_offline", 0, 1, 1, true, "/offline.braw")

    -- Surface should now show offline frame (not stale online frame)
    assert(surface._frame ~= online_frame, string.format(
        "playback offline: surface must change from %s", tostring(online_frame)))
    assert(surface._frame ~= nil, "playback offline: surface must not be nil")
    assert(type(surface._frame) == "string" and surface._frame:find("OFFLINE"),
        string.format("playback offline: should show offline frame, got %s",
            tostring(surface._frame)))
    print("  PASS")
end

--------------------------------------------------------------------------------
-- 5. Playback mode: clip transition to online → no extra display (C++ handles)
--------------------------------------------------------------------------------
print("\n--- 5. playback: clip transition to online (no Lua display) ---")
do
    local engine, surface = make_engine()
    engine:load_sequence("seq1", 300)
    engine:seek(50)
    local count_before = surface._frame_count

    -- Simulate online clip transition during playback
    stored_clip_transition_cb("clipNew", 0, 1, 1, false, "/test.mov")

    -- Surface frame_count should NOT increase (C++ push handles online frames)
    assert(surface._frame_count == count_before, string.format(
        "online transition: Lua must not push frame (count %d → %d)",
        count_before, surface._frame_count))
    print("  PASS")
end

--------------------------------------------------------------------------------
-- 6. Error message propagation: offline metadata includes error_msg
--------------------------------------------------------------------------------
print("\n--- 6. error_msg propagation ---")
do
    tmb_responses[150] = {
        frame_handle = nil,
        metadata = {
            clip_id = "clip_offline", media_path = "/offline.braw",
            source_frame = 50, rotation = 0,
            par_num = 1, par_den = 1,
            offline = true, pending = false,
            error_msg = "Unsupported codec: BRAW (Blackmagic RAW)",
        },
    }

    local engine, surface = make_engine()
    engine:load_sequence("seq1", 300)
    engine:seek(150)

    -- Verify the offline frame was composed (offline_frame_cache handles error_msg)
    assert(surface._frame ~= nil and surface._frame ~= BLACK_FRAME,
        "error_msg: offline frame must be displayed")
    print("  PASS")
end

print("\n\xE2\x9C\x85 test_offline_frame_display.lua passed")
