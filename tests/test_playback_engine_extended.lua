--- Extended PlaybackEngine tests: latch state machine, audio ownership, NSF paths.
--
-- All transport goes through C++ PlaybackController (PLAYBACK mock).
-- Position updates come from stored_position_cb (simulating C++ callbacks).
-- Tests that relied on Lua tick (stuckness, audio-following, TMB_SET_PLAYHEAD,
-- same-frame decimation, reverse monotonicity) have been deleted — C++ owns
-- position advancement.

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

local function clear_timers()
    timer_callbacks = {}
end

-- PLAYBACK mock: tracks calls + stores callbacks
local playback_calls = {}
local stored_position_cb = nil

local function reset_playback()
    playback_calls = {}
    stored_position_cb = nil
end

local function track_pb(name, ...)
    playback_calls[#playback_calls + 1] = { name = name, args = {...} }
end

local function find_pb_call(name)
    for _, c in ipairs(playback_calls) do
        if c.name == name then return c end
    end
    return nil
end

-- Mock qt_constants with PLAYBACK
package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        MEDIA_FILE_OPEN = function() return nil end,
        MEDIA_FILE_INFO = function() return nil end,
        MEDIA_FILE_CLOSE = function() end,
        READER_CREATE = function() return nil end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function() end,
        TMB_SET_PLAYHEAD = function() end,
        TMB_GET_VIDEO_FRAME = function() return nil, { offline = false } end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_controller" end,
        PLAY = function(pc, dir, speed) track_pb("PLAY", dir, speed) end,
        STOP = function(pc) track_pb("STOP") end,
        PARK = function(pc, frame) track_pb("PARK", frame) end,
        SEEK = function(pc, frame) track_pb("SEEK", frame) end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        RELOAD_ALL_CLIPS = function() end,
        SET_SHUTTLE_MODE = function(pc, enabled) track_pb("SET_SHUTTLE_MODE", enabled) end,
        SET_POSITION_CALLBACK = function(pc, fn) stored_position_cb = fn end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        CLOSE = function() end,
        HAS_AUDIO = function() return false end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        PLAY_BURST = function() end,
    },
}

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    ensure_audio_pooled = function()
        return { has_audio = true, audio_sample_rate = 48000 }
    end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
    pre_buffer = function() end,
}

-- Mock logger
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
            return "frame_handle_" .. frame, {
                clip_id = "clip1",
                media_path = "/test.mov",
                source_frame = frame,
                rotation = 0,
                par_num = 1,
                par_den = 1,
                offline = false,
            }
        end
        return nil, nil
    end,
}

-- Configurable audio_at response
local audio_at_map = nil  -- nil = use default

-- Mock Sequence model
local mock_content_end = 100
local mock_sequence = {
    id = "seq1",
    compute_content_end = function() return mock_content_end end,
    get_video_at = function(self, frame) return {} end,
    get_next_video = function() return {} end,
    get_prev_video = function() return {} end,
    get_audio_at = function(self, frame)
        if audio_at_map then
            return audio_at_map[frame] or {}
        end
        if frame >= 0 and frame < 100 then
            return {{
                media_path = "/test.mov",
                source_frame = frame,
                clip = {
                    id = "aclip1",
                    rate = { fps_numerator = 24, fps_denominator = 1 },
                    timeline_start = 0, duration = 100, source_in = 0, source_out = 100,
                },
                track = { id = "track_a1", track_index = 1, muted = false, soloed = false, volume = 1.0 },
                media_fps_num = 24,
                media_fps_den = 1,
            }}
        end
        return {}
    end,
    get_next_audio = function() return {} end,
    get_prev_audio = function() return {} end,
    get_video_in_range = function() return {} end,
    get_audio_in_range = function() return {} end,
    get_track_indices = function() return { 0 } end,
}
package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

-- Mock signals (capture registrations for verification)
local signal_handlers = {}
package.loaded["core.signals"] = {
    connect = function(name, handler, priority)
        signal_handlers[name] = signal_handlers[name] or {}
        signal_handlers[name][#signal_handlers[name] + 1] = {
            handler = handler, priority = priority or 0
        }
        return "conn_" .. name
    end,
    disconnect = function() end,
    emit = function() end,
}

-- Audio mock with call tracking
local function make_tracked_audio()
    local audio = {
        session_initialized = true,
        playing = false,
        has_audio = false,
        max_media_time_us = 10000000,
        _time_us = 0,
        _calls = {},
    }

    local function track_a(name, ...)
        audio._calls[#audio._calls + 1] = { name = name, args = {...} }
    end

    audio.is_ready = function() return audio.session_initialized end
    audio.get_time_us = function() return audio._time_us end
    audio.get_media_time_us = function() return audio._time_us end
    audio.seek = function(t) track_a("seek", t) end
    audio.start = function() track_a("start"); audio.playing = true end
    audio.stop = function() track_a("stop"); audio.playing = false end
    audio.set_speed = function(s) track_a("set_speed", s) end
    audio.set_max_time = function(t) track_a("set_max_time", t) end
    audio.apply_mix = function(tmb, mix_params, edit_time_us)
        track_a("apply_mix", tmb, mix_params, edit_time_us)
        audio.has_audio = (#mix_params > 0)
    end
    audio.latch = function(t) track_a("latch", t) end
    audio.play_burst = function(time, dur)
        track_a("play_burst", time, dur)
    end
    audio.init_session = function() end
    audio.shutdown_session = function() end
    audio.refresh_mix_volumes = function() end

    return audio
end

--------------------------------------------------------------------------------
-- Load PlaybackEngine
--------------------------------------------------------------------------------
local PlaybackEngine = require("core.playback.playback_engine")

--------------------------------------------------------------------------------
-- Test helper
--------------------------------------------------------------------------------

local function make_engine()
    local log = {
        frames_shown = {},
        gaps_shown = 0,
        rotations = {},
        positions = {},
    }

    reset_playback()

    local engine = PlaybackEngine.new({
        on_show_frame = function(frame_handle, metadata)
            log.frames_shown[#log.frames_shown + 1] = {
                handle = frame_handle,
                clip_id = metadata.clip_id,
                source_frame = metadata.source_frame,
                rotation = metadata.rotation,
            }
        end,
        on_show_gap = function()
            log.gaps_shown = log.gaps_shown + 1
        end,
        on_set_rotation = function(degrees)
            log.rotations[#log.rotations + 1] = degrees
        end,
        on_set_par = function() end,
        on_position_changed = function(frame)
            log.positions[#log.positions + 1] = frame
        end,
    })

    return engine, log
end

local function reset()
    clear_timers()
    audio_at_map = nil
end

print("=== test_playback_engine_extended.lua ===")

--------------------------------------------------------------------------------
-- Test 1: Extended latch state machine
--------------------------------------------------------------------------------
print("\n--- extended latch: transport_mode tracking ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()

    -- transport_mode starts "none"
    assert(engine.transport_mode == "none",
        "Expected transport_mode='none' before shuttle, got " .. engine.transport_mode)

    -- shuttle sets transport_mode = "shuttle"
    engine:shuttle(1)
    assert(engine.transport_mode == "shuttle",
        "Expected transport_mode='shuttle' after shuttle(1), got " .. engine.transport_mode)

    -- stop resets to "none"
    engine:stop()
    assert(engine.transport_mode == "none",
        "Expected transport_mode='none' after stop, got " .. engine.transport_mode)

    -- play sets transport_mode = "play"
    engine:play()
    assert(engine.transport_mode == "play",
        "Expected transport_mode='play' after play(), got " .. engine.transport_mode)
    engine:stop()

    print("  transport_mode tracking passed")
end

print("\n--- extended latch: same-direction shuttle while latched is no-op ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)

    engine:shuttle(1)  -- forward shuttle

    -- Simulate C++ position at boundary (frame 99)
    stored_position_cb(99, false)
    assert(engine.latched, "Should be latched at end boundary")
    assert(engine.latched_boundary == "end", "Should be latched at end")

    local pos_before = engine:get_position()
    engine:shuttle(1)  -- same direction while latched: no-op
    assert(engine.latched, "Should still be latched after same-direction shuttle")
    assert(engine:get_position() == pos_before, "Position shouldn't change")

    -- Opposite direction unlatches
    playback_calls = {}
    engine:shuttle(-1)
    assert(not engine.latched, "Should unlatch on opposite direction")
    assert(engine.direction == -1, "Direction should be -1 after unlatch")
    assert(engine.speed == 1, "Speed should reset to 1 after unlatch")
    assert(find_pb_call("PLAY"), "PLAY called on unlatch")

    engine:stop()
    print("  same-direction no-op and unlatch passed")
end

print("\n--- extended latch: multiple latch/unlatch cycles ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)

    -- Cycle 1: forward to end, unlatch backward
    engine:shuttle(1)
    stored_position_cb(99, false)  -- boundary
    assert(engine.latched, "Cycle 1: should latch at end")
    engine:shuttle(-1)
    assert(not engine.latched, "Cycle 1: should unlatch")

    -- Cycle 2: backward to start
    engine:stop()
    engine:shuttle(-1)
    stored_position_cb(0, false)  -- boundary
    assert(engine.latched, "Cycle 2: should latch at start")
    assert(engine.latched_boundary == "start", "Cycle 2: boundary=start")
    engine:shuttle(1)
    assert(not engine.latched, "Cycle 2: should unlatch")
    engine:stop()

    print("  multiple latch/unlatch cycles passed")
end

-- Tests 2-4 (same-frame decimation, reverse monotonicity, reverse speed,
-- stuckness × 2) deleted — C++ owns position advancement.

--------------------------------------------------------------------------------
-- Test 5: Seek during playback audio lifecycle
--------------------------------------------------------------------------------
print("\n--- seek during playback: delegates to C++ ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 200)
    engine:activate_audio()

    engine:play()
    playback_calls = {}
    mock_audio._calls = {}

    -- Seek to frame 50 while playing
    engine:seek(50)

    -- Verify PARK delegated to C++ (seek uses PARK + Lua pull)
    assert(find_pb_call("PARK"), "PARK must be called on controller")

    -- Seek to frame outside audio clip range → clip change triggers apply_mix
    engine:seek(150)
    local saw_apply_mix = false
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "apply_mix" then saw_apply_mix = true end
    end
    assert(saw_apply_mix, "Audio mix resolved at clip boundary")

    engine:stop()
    print("  seek during playback passed")
end

print("\n--- seek while stopped: no audio start ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    mock_audio._calls = {}

    -- Seek while stopped
    engine:seek(50)

    local saw_start = false
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "start" then saw_start = true end
    end

    assert(not saw_start, "Seek while stopped should not start audio")
    print("  seek while stopped passed")
end

--------------------------------------------------------------------------------
-- Test 6: Seek deduplication
--------------------------------------------------------------------------------
print("\n--- seek deduplication: parked same-frame skips ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)

    playback_calls = {}
    engine:seek(30)
    local park_count_1 = 0
    for _, c in ipairs(playback_calls) do
        if c.name == "PARK" then park_count_1 = park_count_1 + 1 end
    end
    assert(park_count_1 == 1, "First seek calls PARK")

    -- Second seek to same frame: skipped (dedup)
    engine:seek(30)
    local park_count_2 = 0
    for _, c in ipairs(playback_calls) do
        if c.name == "PARK" then park_count_2 = park_count_2 + 1 end
    end
    assert(park_count_2 == 1, "Same-frame seek skipped")

    -- Different frame: calls PARK
    engine:seek(31)
    local park_count_3 = 0
    for _, c in ipairs(playback_calls) do
        if c.name == "PARK" then park_count_3 = park_count_3 + 1 end
    end
    assert(park_count_3 == 2, "Different frame calls PARK")

    print("  seek deduplication passed")
end

-- Test 7 (gap→clip audio) deleted — tick-dependent.
-- Tests 10-12 (TMB_SET_PLAYHEAD, video-follows-audio, _last_audio_frame) deleted.

--------------------------------------------------------------------------------
-- Test 8: Audio clip change detection
--------------------------------------------------------------------------------
print("\n--- audio clip change detection ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()

    -- Verify _audio_clips_changed detects differences
    engine.current_audio_clip_ids = { clip1 = true }
    assert(not engine:_audio_clips_changed({ clip1 = true }),
        "Same clip IDs should return false")
    assert(engine:_audio_clips_changed({ clip2 = true }),
        "Different clip ID should return true")
    assert(engine:_audio_clips_changed({ clip1 = true, clip2 = true }),
        "Added clip should return true")
    assert(engine:_audio_clips_changed({}),
        "Removed all clips should return true")

    print("  audio clip change detection passed")
end

--------------------------------------------------------------------------------
-- Test 9: Frame step audio burst
--------------------------------------------------------------------------------
print("\n--- frame step audio burst: play_frame_audio timing ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    mock_audio._calls = {}

    -- play_frame_audio at frame 30
    engine:play_frame_audio(30)

    -- Find play_burst call (goes through Lua fallback since HAS_AUDIO returns false)
    local burst_call = nil
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "play_burst" then burst_call = call end
    end
    assert(burst_call, "play_frame_audio should call play_burst")

    local expected_time = math.floor(30 * 1000000 / 24)
    assert(burst_call.args[1] == expected_time,
        string.format("Burst time should be %d, got %s",
            expected_time, tostring(burst_call.args[1])))

    -- Burst duration: 1.5x frame duration, clamped to [40000, 60000]
    local frame_dur = math.floor(1000000 / 24)
    local expected_burst = math.max(40000, math.min(60000,
        math.floor(frame_dur * 1.5)))
    assert(burst_call.args[2] == expected_burst,
        string.format("Burst duration should be %d, got %s",
            expected_burst, tostring(burst_call.args[2])))

    print("  frame step audio burst timing passed")
end

print("\n--- frame step audio burst: no burst when playing ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()

    engine:play()
    mock_audio._calls = {}

    engine:play_frame_audio(30)

    local burst_count = 0
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "play_burst" then burst_count = burst_count + 1 end
    end
    assert(burst_count == 0, "Should not burst during playback")

    engine:stop()
    print("  no burst when playing passed")
end

print("\n--- frame step audio burst: no burst when not audio owner ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    -- NOT calling activate_audio()
    mock_audio._calls = {}

    engine:play_frame_audio(30)

    local burst_count = 0
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "play_burst" then burst_count = burst_count + 1 end
    end
    assert(burst_count == 0, "Should not burst when not audio owner")

    print("  no burst when not audio owner passed")
end

--------------------------------------------------------------------------------
-- Test 13: activate_audio() must call set_max_time (B10 regression)
--------------------------------------------------------------------------------
print("\n--- B10: activate_audio sets max_media_time_us ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine_a, _ = make_engine()
    engine_a:load_sequence("seq1", 100)
    local a_max = engine_a.max_media_time_us
    assert(a_max > 0, "Engine A max_media_time_us should be positive")

    local engine_b, _ = make_engine()
    engine_b:load_sequence("seq1", 500)
    local b_max = engine_b.max_media_time_us
    assert(b_max > a_max, "Engine B max should be > engine A max")

    -- Activate A — should push A's max_time
    mock_audio._calls = {}
    engine_a:activate_audio()
    local found_a_max = false
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "set_max_time" and call.args[1] == a_max then
            found_a_max = true
        end
    end
    assert(found_a_max,
        string.format("activate_audio(A) must push set_max_time(%d)", a_max))

    -- Transfer: deactivate A, activate B
    mock_audio._calls = {}
    engine_a:deactivate_audio()
    engine_b:activate_audio()
    local found_b_max = false
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "set_max_time" and call.args[1] == b_max then
            found_b_max = true
        end
    end
    assert(found_b_max,
        string.format("activate_audio(B) must push set_max_time(%d)", b_max))

    print("  activate_audio sets max_media_time_us passed")
end

--------------------------------------------------------------------------------
-- Test 14: activate_audio() must clear stale current_audio_clip_ids (B11)
--------------------------------------------------------------------------------
print("\n--- B11: activate_audio clears stale clip IDs ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)

    -- Simulate previous session: engine had audio, cached some clip IDs
    engine.current_audio_clip_ids = { old_clip1 = true, old_clip2 = true }

    -- Now activate audio
    engine:activate_audio()

    -- After activation, apply_mix must be called (stale IDs cleared → change detected)
    local saw_apply_mix = false
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "apply_mix" then
            saw_apply_mix = true
        end
    end
    assert(saw_apply_mix,
        "activate_audio must re-push audio mix (stale clip IDs should be cleared)")

    print("  activate_audio clears stale clip IDs passed")
end

--------------------------------------------------------------------------------
-- Test 15: project_changed must shut down audio session (B12)
--------------------------------------------------------------------------------
print("\n--- B12: project_changed shuts down audio session ---")
do
    reset()

    local mock_audio = make_tracked_audio()
    mock_audio.session_initialized = true
    mock_audio.has_audio = true
    PlaybackEngine.init_audio(mock_audio)

    assert(PlaybackEngine.get_audio() ~= nil,
        "audio must be set before project_changed")
    assert(PlaybackEngine.get_audio().session_initialized,
        "audio session must be initialized before project_changed")

    -- Verify project_changed handler is registered
    assert(signal_handlers["project_changed"],
        "PlaybackEngine must register a project_changed signal handler")
    local found_handler = false
    for _, entry in ipairs(signal_handlers["project_changed"]) do
        if type(entry.handler) == "function" then
            found_handler = true
            entry.handler("new_project_id")
        end
    end
    assert(found_handler,
        "project_changed must have a function handler from playback_engine")

    assert(PlaybackEngine.get_audio() == nil,
        "audio must be nil after project_changed (prevents stale sources)")

    print("  project_changed shuts down audio session passed")
end

--------------------------------------------------------------------------------
-- Test 16 (NSF-F1): _build_audio_mix_params must assert on nil fields
--------------------------------------------------------------------------------
print("\n--- NSF-F1: _build_audio_mix_params asserts on nil fields ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)

    -- nil volume on track → must assert
    local ok, err = pcall(function()
        engine:_build_audio_mix_params({{
            clip = { id = "c1" },
            track = { id = "t1", track_index = 1, muted = false, soloed = false },
        }})
    end)
    assert(not ok, "nil track.volume should assert")
    assert(tostring(err):find("volume"),
        "Error should mention volume, got: " .. tostring(err))

    -- nil muted on track → must assert
    ok, _ = pcall(function()
        engine:_build_audio_mix_params({{
            clip = { id = "c1" },
            track = { id = "t1", track_index = 1, volume = 1.0, soloed = false },
        }})
    end)
    assert(not ok, "nil track.muted should assert")

    -- nil soloed on track → must assert
    ok, _ = pcall(function()
        engine:_build_audio_mix_params({{
            clip = { id = "c1" },
            track = { id = "t1", track_index = 1, volume = 1.0, muted = false },
        }})
    end)
    assert(not ok, "nil track.soloed should assert")

    -- Valid entry passes
    local params = engine:_build_audio_mix_params({{
        clip = { id = "c1" },
        track = { id = "t1", track_index = 1, volume = 0.8, muted = false, soloed = false },
    }})
    assert(#params == 1, "Should return 1 param")
    assert(params[1].volume == 0.8, "Volume should be 0.8 from track")

    print("  _build_audio_mix_params NSF asserts passed")
end

--------------------------------------------------------------------------------
-- Test 17 (NSF-F2): _compute_audio_speed_ratio must assert on nil fps
--------------------------------------------------------------------------------
print("\n--- NSF-F2: _compute_audio_speed_ratio asserts on nil fps ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)

    -- nil media_fps_num → must assert
    local ok, err = pcall(function()
        engine:_compute_audio_speed_ratio({
            media_fps_num = nil,
            media_fps_den = 1,
        })
    end)
    assert(not ok, "nil media_fps_num should assert")
    assert(tostring(err):find("media_fps_num"),
        "Error should mention media_fps_num, got: " .. tostring(err))

    -- nil media_fps_den → must assert
    ok, _ = pcall(function()
        engine:_compute_audio_speed_ratio({
            media_fps_num = 24,
            media_fps_den = nil,
        })
    end)
    assert(not ok, "nil media_fps_den should assert")

    -- media_fps_den == 0 → must assert
    ok, _ = pcall(function()
        engine:_compute_audio_speed_ratio({
            media_fps_num = 24,
            media_fps_den = 0,
        })
    end)
    assert(not ok, "media_fps_den == 0 should assert")

    -- Valid fps → returns ratio
    local ratio = engine:_compute_audio_speed_ratio({
        media_fps_num = 24, media_fps_den = 1,
    })
    assert(ratio == 1.0, "24fps media in 24fps seq should return 1.0")

    -- Audio-only media (rate >= 1000) → returns 1.0
    ratio = engine:_compute_audio_speed_ratio({
        media_fps_num = 48000, media_fps_den = 1,
    })
    assert(ratio == 1.0, "Audio-only media should return 1.0")

    print("  _compute_audio_speed_ratio NSF asserts passed")
end

--------------------------------------------------------------------------------
-- Test 18 (NSF-F3): _try_audio must rethrow errors (fail-fast in dev)
--------------------------------------------------------------------------------
print("\n--- NSF-F3: _try_audio rethrows errors ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()

    -- _try_audio with function that errors → must rethrow
    local ok, err = pcall(function()
        engine:_try_audio(function()
            error("deliberate test error")
        end)
    end)
    assert(not ok, "_try_audio must rethrow errors (fail-fast NSF)")
    assert(tostring(err):find("deliberate test error"),
        "Rethrown error should contain original message, got: " .. tostring(err))

    -- _try_audio with method name that errors → must rethrow
    engine._test_error_fn = function()
        error("method error")
    end
    ok, err = pcall(function()
        engine:_try_audio("_test_error_fn")
    end)
    assert(not ok, "_try_audio must rethrow method errors")
    assert(tostring(err):find("method error"),
        "Rethrown error should contain method message")

    -- _try_audio when not audio owner → no-op (no error)
    engine._audio_owner = false
    ok = pcall(function()
        engine:_try_audio(function()
            error("should not reach")
        end)
    end)
    assert(ok, "_try_audio should no-op when not audio owner")

    print("  _try_audio rethrows errors passed")
end

print("\n✅ test_playback_engine_extended.lua passed")
