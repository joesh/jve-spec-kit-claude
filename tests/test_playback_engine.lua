--- Test: PlaybackEngine transport state machine, boundary latch, audio ownership.
--
-- All transport goes through C++ PlaybackController (PLAYBACK mock).
-- Position updates come from stored_position_cb (simulating C++ callbacks).
-- Clip transitions come from stored_clip_transition_cb.
-- No Lua tick path exists — tests verify the C++ delegation is correct.

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

-- Timer: only needed for non-tick uses (UI debounce, etc.)
local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

local function clear_timers()
    timer_callbacks = {}
end

-- PLAYBACK mock: tracks all C++ PlaybackController calls
local playback_calls = {}
local stored_position_cb = nil
local stored_clip_transition_cb = nil

local function reset_playback()
    playback_calls = {}
    stored_position_cb = nil
    stored_clip_transition_cb = nil
end

local function track(name, ...)
    playback_calls[#playback_calls + 1] = { name = name, args = {...} }
end

local function find_call(name)
    for _, c in ipairs(playback_calls) do
        if c.name == name then return c end
    end
    return nil
end

local function count_calls(name)
    local n = 0
    for _, c in ipairs(playback_calls) do
        if c.name == name then n = n + 1 end
    end
    return n
end

-- Mock qt_constants with PLAYBACK namespace
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
        PLAY = function(pc, dir, speed) track("PLAY", dir, speed) end,
        STOP = function(pc) track("STOP") end,
        PARK = function(pc, frame) track("PARK", frame) end,
        SEEK = function(pc, frame) track("SEEK", frame) end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        RELOAD_ALL_CLIPS = function() end,
        SET_SHUTTLE_MODE = function(pc, enabled) track("SET_SHUTTLE_MODE", enabled) end,
        SET_POSITION_CALLBACK = function(pc, fn) stored_position_cb = fn end,
        SET_CLIP_TRANSITION_CALLBACK = function(pc, fn) stored_clip_transition_cb = fn end,
        CLOSE = function() end,
        HAS_AUDIO = function() return false end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        PLAY_BURST = function() end,
    },
}

-- Mock media_cache (audio functions only)
package.loaded["core.media.media_cache"] = {
    ensure_audio_pooled = function(path)
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
    get_sequence_info = function(seq_id)
        return {
            fps_num = 24, fps_den = 1,
            kind = "timeline", name = "Test Seq",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function(tmb, track_indices, frame)
        -- Default: clip1 for frames 0-99, gap otherwise
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

-- Mock Sequence model
local mock_content_end = 100
local mock_sequence = {
    id = "seq1",
    compute_content_end = function() return mock_content_end end,
    get_video_at = function(self, frame) return {} end,
    get_next_video = function() return {} end,
    get_prev_video = function() return {} end,
    get_audio_at = function() return {} end,
    get_next_audio = function() return {} end,
    get_prev_audio = function() return {} end,
    get_video_in_range = function() return {} end,
    get_audio_in_range = function() return {} end,
    get_track_indices = function() return { 0 } end,
}
package.loaded["models.sequence"] = {
    load = function(id) return mock_sequence end,
}

-- Mock Track model (default: 1 audio track)
package.loaded["models.track"] = {
    find_by_sequence = function(seq_id, track_type)
        if track_type == "AUDIO" then
            return {
                { id = "t1", track_index = 0, volume = 1.0, muted = false, soloed = false },
            }
        end
        return {}
    end,
}

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

--------------------------------------------------------------------------------
-- Test Helper: create engine with tracking callbacks
--------------------------------------------------------------------------------

local function make_engine()
    local log = {
        frames_shown = {},
        gaps_shown = 0,
        rotations = {},
        pars = {},
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
        on_set_par = function(num, den)
            log.pars[#log.pars + 1] = {num, den}
        end,
        on_position_changed = function(frame)
            log.positions[#log.positions + 1] = frame
        end,
    })

    return engine, log
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

print("=== test_playback_engine.lua ===")

-- ─── Test 1: Constructor validates config ───
print("\n--- constructor validation ---")
do
    local ok, _ = pcall(PlaybackEngine.new, {})
    assert(not ok, "missing callbacks should assert")
    print("  missing callbacks: asserts ok")

    ok, _ = pcall(PlaybackEngine.new, {
        on_show_frame = function() end,
        on_show_gap = function() end,
        on_set_rotation = function() end,
        on_set_par = function() end,
        -- missing on_position_changed
    })
    assert(not ok, "missing on_position_changed should assert")
    print("  missing on_position_changed: asserts ok")

    -- missing on_set_par specifically
    ok, _ = pcall(PlaybackEngine.new, {
        on_show_frame = function() end,
        on_show_gap = function() end,
        on_set_rotation = function() end,
        -- missing on_set_par
        on_position_changed = function() end,
    })
    assert(not ok, "missing on_set_par should assert")
    print("  missing on_set_par: asserts ok")
end

-- ─── Test 2: load_sequence sets fps and total_frames ───
print("\n--- load_sequence ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    assert(engine.fps_num == 24, "fps_num")
    assert(engine.fps_den == 1, "fps_den")
    assert(engine.total_frames == 100, "total_frames")
    assert(engine.sequence == mock_sequence, "sequence object stored")
    assert(engine:get_position() == 0, "position starts at 0")
    assert(engine._playback_controller == "mock_controller",
        "controller created during load")
    print("  ok")
end

-- ─── Test 3: play → PLAYBACK.PLAY called → position callback → stop ───
print("\n--- play delegates to C++ → position callback → stop ---")
do
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    playback_calls = {}  -- reset after load_sequence setup

    engine:play()
    assert(engine:is_playing(), "should be playing")
    assert(engine.direction == 1, "forward")
    assert(engine.speed == 1, "1x")

    -- Verify PLAY was called on controller
    local play_call = find_call("PLAY")
    assert(play_call, "PLAYBACK.PLAY must be called")
    assert(play_call.args[1] == 1, "direction=1")
    assert(play_call.args[2] == 1.0, "speed=1.0")

    -- Simulate C++ position callback (as if displayLinkTick advanced to frame 5)
    assert(stored_position_cb, "position callback must be set")
    stored_position_cb(5, false)
    assert(engine:get_position() == 5, "position updated to 5")
    assert(#log.positions > 0, "position callback fired")

    -- Simulate boundary stop from C++
    stored_position_cb(99, true)
    assert(not engine:is_playing(), "stopped from boundary callback")
    assert(engine:get_position() == 99, "at boundary frame")
    print("  ok")
end

-- ─── Test 4: shuttle speed ramping and unwinding ───
print("\n--- shuttle speed ramp ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:shuttle(1)  -- forward 1x
    assert(engine.speed == 1, "1x")
    assert(engine.transport_mode == "shuttle")

    engine:shuttle(1)  -- forward 2x
    assert(engine.speed == 2, "2x")

    engine:shuttle(1)  -- forward 4x
    assert(engine.speed == 4, "4x")

    engine:shuttle(1)  -- forward 8x
    assert(engine.speed == 8, "8x")

    engine:shuttle(1)  -- 8x cap
    assert(engine.speed == 8, "8x cap")

    -- Unwind: opposite direction slows
    engine:shuttle(-1)  -- 4x
    assert(engine.speed == 4, "unwind to 4x")

    engine:shuttle(-1)  -- 2x
    assert(engine.speed == 2, "unwind to 2x")

    engine:shuttle(-1)  -- 1x
    assert(engine.speed == 1, "unwind to 1x")

    engine:shuttle(-1)  -- stop (unwind past 1x)
    assert(not engine:is_playing(), "unwound to stop")
    print("  ok")
end

-- ─── Test 5: boundary stop in play mode (via position callback) ───
print("\n--- boundary stop (play mode, via position callback) ---")
do
    mock_content_end = 5
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 5)

    engine:play()
    assert(engine:is_playing(), "should be playing")

    -- Simulate C++ boundary stop: position callback with stopped=true
    stored_position_cb(4, true)
    assert(not engine:is_playing(), "stopped at boundary")
    assert(engine:get_position() == 4, "parked at last frame")
    assert(not engine.latched, "play mode doesn't latch")
    mock_content_end = 100
    print("  ok")
end

-- ─── Test 6: boundary latch in shuttle mode + unlatch ───
print("\n--- boundary latch (shuttle mode, via position callback) ---")
do
    mock_content_end = 5
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 5)

    engine:shuttle(1)  -- forward shuttle
    assert(engine:is_playing(), "playing")
    assert(engine.transport_mode == "shuttle", "shuttle mode")

    -- Simulate C++ position at boundary (frame 4 = total_frames-1), NOT stopped
    -- (C++ shuttle keeps ticking at boundary with m_hit_boundary=true)
    stored_position_cb(4, false)
    assert(engine:is_playing(), "still playing (latched)")
    assert(engine.latched, "latched at boundary")
    assert(engine.latched_boundary == "end", "latched at end")
    assert(engine:get_position() == 4, "at last frame")

    -- Same direction while latched → no-op
    playback_calls = {}
    engine:shuttle(1)
    assert(engine.latched, "still latched")

    -- Opposite direction → unlatch + resume via PLAYBACK.PLAY
    engine:shuttle(-1)
    assert(not engine.latched, "unlatched")
    assert(engine.direction == -1, "reversed")
    assert(engine.speed == 1, "1x after unlatch")
    assert(find_call("PLAY"), "PLAY called on unlatch")
    mock_content_end = 100
    print("  ok")
end

-- ─── Test 9: gap display (via seek → PLAYBACK.SEEK) ───
-- Tests 7 (audio following) and 8 (stuckness detection) deleted —
-- C++ two-clock owns position advancement.
print("\n--- seek triggers PLAYBACK.SEEK ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 200)
    playback_calls = {}

    engine:seek(150)
    local park_call = find_call("PARK")
    assert(park_call, "PARK called")
    assert(park_call.args[1] == 150, "parked at frame 150")
    print("  ok")
end

-- ─── Test 10: clip transition callback triggers rotation ───
print("\n--- clip transition callback + rotation ---")
do
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    log.rotations = {}

    -- Simulate C++ clip transition: clipA with rotation=0
    assert(stored_clip_transition_cb, "clip transition callback must be set")
    stored_clip_transition_cb("clipA", 0, 1, 1, false, "/test.mov", 0)
    assert(#log.rotations == 1, "first clip → rotation callback")
    assert(log.rotations[1] == 0, "clipA rotation=0")

    -- Same clip again → no new callback
    stored_clip_transition_cb("clipA", 0, 1, 1, false, "/test.mov", 0)
    assert(#log.rotations == 1, "same clip → no rotation callback")

    -- Different clip → rotation callback
    stored_clip_transition_cb("clipB", 90, 1, 1, false, "/test2.mov", 10)
    assert(#log.rotations == 2, "clip switch → rotation callback")
    assert(log.rotations[2] == 90, "clipB rotation=90")

    print("  ok")
end

-- ─── Test 10b: clip transition callback triggers PAR ───
print("\n--- clip transition callback + PAR ---")
do
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    log.pars = {}

    -- clipC: square pixels (1:1)
    stored_clip_transition_cb("clipC", 0, 1, 1, false, "/test3.mov", 20)
    assert(#log.pars == 1, "first clip → PAR callback, got " .. #log.pars)
    assert(log.pars[1][1] == 1 and log.pars[1][2] == 1,
        string.format("clipC PAR should be 1:1, got %d:%d", log.pars[1][1], log.pars[1][2]))

    -- clipD: anamorphic HD (4:3)
    stored_clip_transition_cb("clipD", 0, 4, 3, false, "/test4.mov", 30)
    assert(#log.pars == 2, "clip switch → PAR callback")
    assert(log.pars[2][1] == 4 and log.pars[2][2] == 3,
        string.format("clipD PAR should be 4:3, got %d:%d", log.pars[2][1], log.pars[2][2]))

    -- Same clip → no new callback
    stored_clip_transition_cb("clipD", 0, 4, 3, false, "/test4.mov", 30)
    assert(#log.pars == 2, "same clip → no PAR callback")

    print("  ok")
end

-- ─── Test 11: seek while playing → SEEK called ───
print("\n--- seek while playing ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:play()
    playback_calls = {}

    engine:seek(50)
    assert(engine:is_playing(), "still playing after seek")
    assert(engine:get_position() == 50, "seeked to 50")
    assert(find_call("PARK"), "PARK called")

    engine:stop()
    print("  ok")
end

-- ─── Test 12: seek while stopped (parked) + dedup ───
print("\n--- seek while stopped ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    playback_calls = {}
    engine:seek(25)
    assert(engine:get_position() == 25, "seeked to 25")
    assert(count_calls("PARK") == 1, "PARK called once")

    -- Redundant seek to same frame → skip
    engine:seek(25)
    assert(count_calls("PARK") == 1, "redundant seek skipped")
    print("  ok")
end

-- ─── Test 13: audio ownership ───
print("\n--- audio ownership ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    assert(not engine._audio_owner, "not owner initially")

    engine:activate_audio()
    assert(engine._audio_owner, "owner after activate")

    engine:deactivate_audio()
    assert(not engine._audio_owner, "not owner after deactivate")
    print("  ok")
end

-- ─── Test 14: slow_play ───
print("\n--- slow_play ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    playback_calls = {}

    engine:slow_play(-1)
    assert(engine:is_playing(), "playing")
    assert(engine.speed == 0.5, "0.5x")
    assert(engine.direction == -1, "reverse")
    assert(engine.transport_mode == "shuttle", "shuttle mode for slow_play")

    -- Verify PLAY called with correct params
    local play_call = find_call("PLAY")
    assert(play_call, "PLAY called")
    assert(play_call.args[1] == -1, "direction=-1")
    assert(play_call.args[2] == 0.5, "speed=0.5")

    engine:stop()
    print("  ok")
end

-- Test 15 (tick generation) deleted — no more Lua ticks.

-- ─── Test 16: reverse shuttle → latch at start boundary ───
print("\n--- reverse latch at start (via position callback) ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:shuttle(-1)  -- reverse
    assert(engine.transport_mode == "shuttle", "shuttle mode")

    -- Simulate C++ position at start boundary, not stopped
    stored_position_cb(0, false)
    assert(engine.latched, "latched")
    assert(engine.latched_boundary == "start", "latched at start")
    assert(engine:get_position() == 0, "at frame 0")
    engine:stop()
    print("  ok")
end

-- ─── Test 17: get_status ───
print("\n--- get_status ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    assert(engine:get_status() == "stopped", "stopped status")

    engine:shuttle(1)
    assert(engine:get_status() == "> 1.0x", "forward 1x status")

    engine:shuttle(1)
    assert(engine:get_status() == "> 2.0x", "forward 2x status")

    engine:stop()
    engine:shuttle(-1)
    assert(engine:get_status() == "< 1.0x", "reverse 1x status")

    engine:stop()
    print("  ok")
end

-- ─── Test 18: has_source ───
print("\n--- has_source ---")
do
    local engine, _ = make_engine()
    assert(not engine:has_source(), "no source before load")

    engine:load_sequence("seq1", 100)
    assert(engine:has_source(), "has source after load")
    print("  ok")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- NSF: Error Paths
-- ═══════════════════════════════════════════════════════════════════════════

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. " (expected assert, got success)")
    return err
end

-- ─── Test 19: seek without sequence loaded → assert ───
print("\n--- seek without sequence asserts ---")
do
    local engine, _ = make_engine()
    expect_assert(function() engine:seek(0) end,
        "seek without sequence")
    print("  ok")
end

-- ─── Test 20: shuttle with dir=0 → assert ───
print("\n--- shuttle dir=0 asserts ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    expect_assert(function() engine:shuttle(0) end,
        "shuttle dir=0")
    print("  ok")
end

-- ─── Test 21: seek with nil frame → assert ───
print("\n--- seek nil frame asserts ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    expect_assert(function() engine:seek(nil) end,
        "seek nil frame")
    print("  ok")
end

-- ─── Test 22: seek with negative frame → assert ───
print("\n--- seek negative frame asserts ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    expect_assert(function() engine:seek(-1) end,
        "seek negative frame")
    print("  ok")
end

-- ─── Test 23: slow_play with dir=0 → assert ───
print("\n--- slow_play dir=0 asserts ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    expect_assert(function() engine:slow_play(0) end,
        "slow_play dir=0")
    print("  ok")
end

-- ─── Test 24: load_sequence with empty string → assert ───
print("\n--- load_sequence empty string asserts ---")
do
    local engine, _ = make_engine()
    expect_assert(function() engine:load_sequence("") end,
        "load_sequence empty string")
    print("  ok")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- NSF: Boundary Conditions
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Test 25: total_frames = 1 (single frame) ───
print("\n--- single frame sequence ---")
do
    mock_content_end = 1
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 1)

    assert(engine.total_frames == 1, "total_frames=1")

    -- Play → C++ will immediately boundary-stop via position callback
    engine:play()
    stored_position_cb(0, true)
    assert(not engine:is_playing(), "stopped (only 1 frame)")
    assert(engine:get_position() == 0, "at frame 0")
    mock_content_end = 100
    print("  ok")
end

-- ─── Test 26: play when already playing → no-op ───
print("\n--- play when already playing ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:play()
    playback_calls = {}

    engine:play()  -- should be no-op
    assert(not find_call("PLAY"), "no second PLAY call")

    engine:stop()
    print("  ok")
end

-- ─── Test 27: stop when already stopped → no error ───
print("\n--- stop when already stopped ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:stop()  -- already stopped, should not error
    engine:stop()  -- again, still fine
    assert(not engine:is_playing(), "still stopped")
    print("  ok")
end

-- ─── Test 28: load_sequence while playing → stops first ───
print("\n--- load_sequence while playing ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:play()
    assert(engine:is_playing(), "playing before reload")

    engine:load_sequence("seq1", 50)
    assert(not engine:is_playing(), "stopped after reload")
    assert(engine.total_frames == 50, "new total_frames")
    assert(engine:get_position() == 0, "position reset")
    print("  ok")
end

-- ─── Test 29: seek to frame 0 (start boundary, parked) ───
print("\n--- seek to frame 0 ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:seek(50)
    engine:seek(0)
    assert(engine:get_position() == 0, "at frame 0")
    -- Both seeks should have called PARK
    assert(count_calls("PARK") >= 2, "PARK called for both seeks")
    print("  ok")
end

-- ─── Test 30: seek to last frame (end boundary, parked) ───
print("\n--- seek to last frame ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:seek(99)
    assert(engine:get_position() == 99, "at frame 99")
    print("  ok")
end

-- ─── Test 31: play() refreshes total_frames after clip added ───
print("\n--- play refreshes stale total_frames ---")
do
    mock_content_end = 0

    local engine, _ = make_engine()
    clear_timers()

    engine:load_sequence("seq1")
    assert(engine.total_frames == 1,
        "empty sequence: total_frames=" .. engine.total_frames .. " expected 1")

    -- Simulate clip insertion: content_end now 100 frames
    mock_content_end = 100

    engine:play()
    assert(engine.total_frames == 100,
        "after play: total_frames=" .. engine.total_frames .. " expected 100")
    assert(engine.max_media_time_us > 0,
        "after play: max_media_time_us=" .. engine.max_media_time_us .. " expected > 0")

    engine:stop()
    mock_content_end = 100
    print("  ok")
end

-- ─── Test 32: shuttle() refreshes stale total_frames ───
print("\n--- shuttle refreshes stale total_frames ---")
do
    mock_content_end = 0

    local engine, _ = make_engine()
    clear_timers()

    engine:load_sequence("seq1")
    assert(engine.total_frames == 1, "empty")

    mock_content_end = 50
    engine:shuttle(1)
    assert(engine.total_frames == 50,
        "after shuttle: total_frames=" .. engine.total_frames .. " expected 50")

    engine:stop()
    mock_content_end = 100
    print("  ok")
end

-- ─── Test 33: load_sequence stores audio_sample_rate ───
print("\n--- load_sequence stores audio_sample_rate ---")
do
    local engine = make_engine()
    engine:load_sequence("seq1")
    assert(engine.audio_sample_rate == 48000,
        "audio_sample_rate should be 48000, got " .. tostring(engine.audio_sample_rate))
    print("  ok")
end

-- ─── Test 34: offline clip → rotation=0, PAR=1:1 (via clip transition) ───
print("\n--- offline clip resets rotation + PAR ---")
do
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    log.rotations = {}
    log.pars = {}

    -- Online clip with rotation
    stored_clip_transition_cb("clipA", 90, 4, 3, false, "/online.mov", 0)
    assert(log.rotations[1] == 90, "online: rotation=90")
    assert(log.pars[1][1] == 4 and log.pars[1][2] == 3, "online: PAR=4:3")

    -- Offline clip → upright, square pixels
    stored_clip_transition_cb("clipB", 180, 16, 9, true, "/offline.braw", 50)
    assert(log.rotations[2] == 0, "offline: rotation=0")
    assert(log.pars[2][1] == 1 and log.pars[2][2] == 1, "offline: PAR=1:1")

    print("  ok")
end

-- ─── Test: _configure_and_start_audio activates C++ audio after late init ───
-- NSF-F3: If activate_audio() ran before the audio session was lazily
-- initialized (fps_num not set at focus time), ACTIVATE_AUDIO was skipped.
-- _configure_and_start_audio must call ACTIVATE_AUDIO if HAS_AUDIO is false.
print("\n--- _configure_and_start_audio: late ACTIVATE_AUDIO ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Inject a mock audio_playback with session already initialized
    -- (simulates _init_audio_session having been called by _if_clip_changed)
    local mock_audio = {
        session_initialized = true,
        aop = "mock_aop",
        sse = "mock_sse",
        session_sample_rate = 48000,
        session_channels = 2,
        is_ready = function() return true end,
        set_max_time = function() end,
        apply_mix = function() end,
        init_session = function() end,
    }
    PlaybackEngine.init_audio(mock_audio)

    -- Track ACTIVATE_AUDIO and HAS_AUDIO calls
    local activate_called = false
    local has_audio_returns = false  -- simulates race: C++ doesn't know yet
    local qt = package.loaded["core.qt_constants"]
    local orig_has = qt.PLAYBACK.HAS_AUDIO
    local orig_activate = qt.PLAYBACK.ACTIVATE_AUDIO
    qt.PLAYBACK.HAS_AUDIO = function() return has_audio_returns end
    qt.PLAYBACK.ACTIVATE_AUDIO = function(pc, aop, sse, sr, ch)
        activate_called = true
        track("ACTIVATE_AUDIO", aop, sse, sr, ch)
    end

    -- Set audio ownership (simulates activate_audio having already run but
    -- ACTIVATE_AUDIO was skipped because fps_num was nil at the time)
    engine._audio_owner = true
    engine.current_audio_clip_ids = {}

    -- Call _configure_and_start_audio (called from play path)
    engine:_configure_and_start_audio()

    -- Verify ACTIVATE_AUDIO was called since HAS_AUDIO returned false
    assert(activate_called,
        "_configure_and_start_audio must call ACTIVATE_AUDIO when HAS_AUDIO=false")
    local call = find_call("ACTIVATE_AUDIO")
    assert(call, "ACTIVATE_AUDIO call must be tracked")
    assert(call.args[1] == "mock_aop", "aop passed correctly")
    assert(call.args[2] == "mock_sse", "sse passed correctly")
    assert(call.args[3] == 48000, "sample_rate passed correctly")
    assert(call.args[4] == 2, "channels passed correctly")
    print("  _configure_and_start_audio calls ACTIVATE_AUDIO when HAS_AUDIO=false: ok")

    -- Phase 2: When HAS_AUDIO returns true, should NOT call again
    activate_called = false
    has_audio_returns = true
    playback_calls = {}
    engine:_configure_and_start_audio()
    assert(not activate_called,
        "_configure_and_start_audio must NOT call ACTIVATE_AUDIO when HAS_AUDIO=true")
    print("  _configure_and_start_audio skips ACTIVATE_AUDIO when HAS_AUDIO=true: ok")

    -- Restore mocks
    qt.PLAYBACK.HAS_AUDIO = orig_has
    qt.PLAYBACK.ACTIVATE_AUDIO = orig_activate
    PlaybackEngine.init_audio(nil)
    print("  ok")
end

-- ─── Regression: session init when no audio clips at park position ───
-- BUG: _init_audio_session was only called from _if_clip_changed_update_audio_mix,
-- gated on clip-change dedup. If park position has no audio clips (empty→empty),
-- session was never initialized → has_audio=0 forever.
-- Fix: _configure_and_start_audio and activate_audio init session eagerly.
print("\n--- session init: no audio clips at park position ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Mock audio_playback with session NOT yet initialized
    local init_called = false
    local mock_audio  -- forward declaration for closure
    mock_audio = {
        session_initialized = false,
        aop = nil,
        sse = nil,
        session_sample_rate = nil,
        session_channels = nil,
        is_ready = function() return false end,
        set_max_time = function() end,
        apply_mix = function() end,
        init_session = function(sr, ch)
            init_called = true
            mock_audio.session_initialized = true
            mock_audio.aop = "mock_aop"
            mock_audio.sse = "mock_sse"
            mock_audio.session_sample_rate = sr
            mock_audio.session_channels = ch
            mock_audio.is_ready = function() return true end
        end,
    }
    -- Install the mock as the audio_playback module (for _init_audio_session's require)
    local orig_audio_pb = package.loaded["core.media.audio_playback"]
    package.loaded["core.media.audio_playback"] = mock_audio
    PlaybackEngine.init_audio(mock_audio)

    -- Set audio_sample_rate (needed by _init_audio_session assert)
    engine.audio_sample_rate = 48000

    -- Mock SSE/AOP bindings (needed by _init_audio_session guard)
    local qt = package.loaded["core.qt_constants"]
    qt.SSE = { CREATE = function() return "mock_sse_obj" end }
    qt.AOP = { OPEN = function() return "mock_aop_obj" end }

    -- Track ACTIVATE_AUDIO
    local activate_called = false
    local orig_has = qt.PLAYBACK.HAS_AUDIO
    local orig_activate = qt.PLAYBACK.ACTIVATE_AUDIO
    qt.PLAYBACK.HAS_AUDIO = function() return false end
    qt.PLAYBACK.ACTIVATE_AUDIO = function()
        activate_called = true
    end

    engine._audio_owner = true
    engine.current_audio_clip_ids = {}

    -- _configure_and_start_audio must init session even though no clips changed
    engine:_configure_and_start_audio()

    assert(init_called,
        "_configure_and_start_audio must call _init_audio_session when session not initialized")
    assert(mock_audio.session_initialized,
        "session must be initialized after _configure_and_start_audio")
    assert(activate_called,
        "ACTIVATE_AUDIO must be called after session init")
    print("  session init triggered by _configure_and_start_audio: ok")

    -- Restore
    qt.PLAYBACK.HAS_AUDIO = orig_has
    qt.PLAYBACK.ACTIVATE_AUDIO = orig_activate
    qt.SSE = nil
    qt.AOP = nil
    package.loaded["core.media.audio_playback"] = orig_audio_pb
    PlaybackEngine.init_audio(nil)
    print("  ok")
end

-- ─── NSF-F3: _try_audio rethrows errors ───
print("\n--- NSF-F3: _try_audio rethrows errors ---")
do
    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)
    engine._audio_owner = true

    local ok, err = pcall(function()
        engine:_try_audio(function()
            error("BOOM")
        end)
    end)
    assert(not ok, "_try_audio must not swallow errors")
    assert(err:find("BOOM"), "error message preserved")
    print("  _try_audio rethrows errors passed")
end

-- ─── Mix params pushed for ALL audio tracks at play start ───
-- Regression: park at frame with no audio clips → _if_clip_changed_update_audio_mix
-- dedupes (empty→empty) → SetAudioMixParams never called → TMB has no tracks → silence.
-- Fix: _configure_and_start_audio pushes ALL audio tracks, not position-dependent entries.
print("\n--- mix params pushed for ALL audio tracks at play start ---")
do
    local qt = package.loaded["core.qt_constants"]

    -- Set up audio mocks
    qt.SSE = { CREATE = function() return "mock_sse" end, RESET = function() end }
    qt.AOP = {
        CREATE = function() return "mock_aop" end,
        SET_SAMPLE_RATE = function() end,
        SET_CHANNELS = function() end,
        STOP = function() end,
        FLUSH = function() end,
    }

    -- Ensure we have the REAL audio_playback module (not mock from previous test)
    local orig_audio_pb = package.loaded["core.media.audio_playback"]
    package.loaded["core.media.audio_playback"] = nil

    -- Track the resolved params sent to TMB
    local sent_mix_params = nil
    local orig_tmb_set = qt.EMP.TMB_SET_AUDIO_MIX_PARAMS
    qt.EMP.TMB_SET_AUDIO_MIX_PARAMS = function(tmb, resolved, sr, ch)
        sent_mix_params = resolved
    end

    -- Mock Track model: 2 audio tracks in the sequence
    local orig_track = package.loaded["models.track"]
    package.loaded["models.track"] = {
        find_by_sequence = function(seq_id, track_type)
            if track_type == "AUDIO" then
                return {
                    { id = "t1", track_index = 0, volume = 1.0, muted = false, soloed = false },
                    { id = "t2", track_index = 1, volume = 0.8, muted = false, soloed = false },
                }
            end
            return {}
        end,
    }

    -- Mock sequence: NO audio clips at frame 0 (the park position)
    local orig_get_audio_at = mock_sequence.get_audio_at
    mock_sequence.get_audio_at = function() return {} end

    local engine, _ = make_engine()
    engine:load_sequence("seq1", 100)

    -- Init audio infrastructure
    local audio_pb = require("core.media.audio_playback")
    audio_pb.session_initialized = false
    audio_pb.aop = nil
    audio_pb.sse = nil
    PlaybackEngine.init_audio(audio_pb)

    engine._audio_owner = true
    engine.current_audio_clip_ids = {}
    engine.audio_sample_rate = 48000

    -- Simulate session already initialized (bypass real init_session which needs AOP.OPEN)
    audio_pb.session_initialized = true
    audio_pb.aop = "mock_aop"
    audio_pb.sse = "mock_sse"
    audio_pb.session_sample_rate = 48000
    audio_pb.session_channels = 2

    -- HAS_AUDIO returns false → late ACTIVATE_AUDIO path
    local orig_has = qt.PLAYBACK.HAS_AUDIO
    qt.PLAYBACK.HAS_AUDIO = function() return false end
    local orig_activate = qt.PLAYBACK.ACTIVATE_AUDIO
    qt.PLAYBACK.ACTIVATE_AUDIO = function() end

    -- The key test: _configure_and_start_audio at frame 0 with NO audio clips
    engine:_configure_and_start_audio()

    -- Assert: mix params MUST have been sent to TMB with both tracks
    assert(sent_mix_params,
        "SetAudioMixParams must be called even when no audio clips at park position")
    assert(#sent_mix_params == 2, string.format(
        "expected 2 track params, got %d", #sent_mix_params))
    assert(sent_mix_params[1].track_index == 0,
        "first track must be index 0")
    assert(sent_mix_params[2].track_index == 1,
        "second track must be index 1")
    print("  mix params pushed for all audio tracks: ok")

    -- Restore
    qt.PLAYBACK.HAS_AUDIO = orig_has
    qt.PLAYBACK.ACTIVATE_AUDIO = orig_activate
    qt.EMP.TMB_SET_AUDIO_MIX_PARAMS = orig_tmb_set
    mock_sequence.get_audio_at = orig_get_audio_at
    package.loaded["models.track"] = orig_track
    package.loaded["core.media.audio_playback"] = orig_audio_pb
    qt.SSE = nil
    qt.AOP = nil
    PlaybackEngine.init_audio(nil)
    print("  ok")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- NSF /et: on_model_changed, calc_frame_from_time_us, seek_to_frame,
--          _compute_video_speed_ratio
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Test: on_model_changed clears dedup and re-seeks ───
print("\n--- on_model_changed ---")
do
    local engine = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Seek to 50 — sets _last_committed_frame = 50
    engine:seek(50)
    reset_playback()

    -- seek(50) again → dedup skip (same frame)
    engine:seek(50)
    assert(count_calls("PARK") == 0,
        "seek(50) after seek(50) should be deduped (no PARK call)")

    -- on_model_changed(50) → clears dedup, re-seeks to 50
    reset_playback()
    engine:on_model_changed(50)
    assert(count_calls("PARK") == 1,
        "on_model_changed should clear dedup and re-seek (PARK called)")
    print("  clears dedup and re-seeks: ok")
end

do
    local engine = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- on_model_changed re-seeks → PARK called, position updated internally
    engine:on_model_changed(25)
    assert(find_call("PARK"), "on_model_changed should call PARK (via seek)")
    assert(engine:get_position() == 25,
        "on_model_changed should update position to 25, got " .. tostring(engine:get_position()))
    print("  updates position and calls PARK: ok")
end

-- ─── Test: calc_frame_from_time_us ───
print("\n--- calc_frame_from_time_us ---")
do
    local engine, _ = make_engine()
    clear_timers()

    -- Before load_sequence → fps not set → assert
    expect_assert(function() engine:calc_frame_from_time_us(1000000) end,
        "calc_frame_from_time_us without fps")
    print("  fps not set asserts: ok")
end

do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- 24fps: 1 frame = 1/24 s = 41666.67 us
    -- t_us = 0 → frame 0
    local f0 = engine:calc_frame_from_time_us(0)
    assert(f0 == 0, "calc_frame_from_time_us(0) should be 0, got " .. tostring(f0))

    -- t_us = 1000000 (1 second) → frame 24 at 24fps
    local f24 = engine:calc_frame_from_time_us(1000000)
    assert(f24 == 24, "calc_frame_from_time_us(1s) should be 24, got " .. tostring(f24))
    print("  correct frame calculation: ok")
end

-- ─── Test: seek_to_frame asserts ───
print("\n--- seek_to_frame ---")
do
    local engine, _ = make_engine()
    clear_timers()

    -- Before load → fps not set → assert
    expect_assert(function() engine:seek_to_frame(10) end,
        "seek_to_frame without fps")
    print("  fps not set asserts: ok")
end

do
    local engine, _ = make_engine()
    clear_timers()

    -- Non-number → assert
    expect_assert(function() engine:seek_to_frame("ten") end,
        "seek_to_frame with string")
    print("  non-number asserts: ok")
end

do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Happy path: seek_to_frame floors and delegates to seek
    engine:seek_to_frame(10.7)
    assert(find_call("PARK"), "seek_to_frame should call PARK")
    local park = find_call("PARK")
    assert(park.args[1] == 10,
        "seek_to_frame(10.7) should floor to 10, got " .. tostring(park.args[1]))
    print("  floors and delegates to seek: ok")
end

-- ─── Test: _compute_video_speed_ratio ───
print("\n--- _compute_video_speed_ratio ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Normal speed: source_out - source_in = duration
    local entry = { clip = { id = "c1", source_in = 0, source_out = 100, duration = 100 } }
    local ratio = engine:_compute_video_speed_ratio(entry)
    assert(ratio == 1.0,
        "normal speed should snap to 1.0, got " .. tostring(ratio))
    print("  normal speed (1.0): ok")
end

do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Reverse clip: source_out < source_in → negative ratio
    local entry = { clip = { id = "c2", source_in = 100, source_out = 0, duration = 100 } }
    local ratio = engine:_compute_video_speed_ratio(entry)
    assert(ratio == -1.0,
        "reverse normal speed should snap to -1.0, got " .. tostring(ratio))
    print("  reverse speed (-1.0): ok")
end

do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Slow motion: 50 source frames over 100 timeline frames
    local entry = { clip = { id = "c3", source_in = 0, source_out = 50, duration = 100 } }
    local ratio = engine:_compute_video_speed_ratio(entry)
    assert(ratio == 0.5,
        "slow motion should be 0.5, got " .. tostring(ratio))
    print("  slow motion (0.5): ok")
end

do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Error: nil source_out → assert
    expect_assert(function()
        engine:_compute_video_speed_ratio({ clip = { id = "bad", source_in = 0, source_out = nil, duration = 100 } })
    end, "_compute_video_speed_ratio nil source_out")
    print("  nil source_out asserts: ok")

    -- Error: nil source_in → assert
    expect_assert(function()
        engine:_compute_video_speed_ratio({ clip = { id = "bad", source_in = nil, source_out = 100, duration = 100 } })
    end, "_compute_video_speed_ratio nil source_in")
    print("  nil source_in asserts: ok")

    -- Error: nil duration → assert
    expect_assert(function()
        engine:_compute_video_speed_ratio({ clip = { id = "bad", source_in = 0, source_out = 100, duration = nil } })
    end, "_compute_video_speed_ratio nil duration")
    print("  nil duration asserts: ok")

    -- Error: zero source_range → assert
    expect_assert(function()
        engine:_compute_video_speed_ratio({ clip = { id = "bad", source_in = 50, source_out = 50, duration = 100 } })
    end, "_compute_video_speed_ratio zero source_range")
    print("  zero source_range asserts: ok")

    -- Error: zero duration → assert
    expect_assert(function()
        engine:_compute_video_speed_ratio({ clip = { id = "bad", source_in = 0, source_out = 100, duration = 0 } })
    end, "_compute_video_speed_ratio zero duration")
    print("  zero duration asserts: ok")
end

print("\n✅ test_playback_engine.lua passed")
