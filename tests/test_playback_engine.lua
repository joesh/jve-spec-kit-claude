--- Test: PlaybackEngine unified tick, transport, audio-following, boundary latch
--
-- Tests the instantiable PlaybackEngine class. All modules (Renderer, Mixer,
-- Sequence, media_cache) are mocked at module level so tests focus on the
-- tick algorithm, transport state machine, and audio change detection.

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

-- Timer: captures callback for manual tick pumping
local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

local function pump_tick()
    assert(#timer_callbacks > 0, "pump_tick: no pending timer callback")
    local cb = table.remove(timer_callbacks, 1)
    cb()
end

local function clear_timers()
    timer_callbacks = {}
end

-- Mock qt_constants
package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        ASSET_OPEN = function() return nil end,
        ASSET_INFO = function() return nil end,
        ASSET_CLOSE = function() end,
        READER_CREATE = function() return nil end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
    },
}

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    activate = function() return { rotation = 0 } end,
    get_video_frame = function(frame, ctx) return "frame_" .. frame end,
    set_playhead = function() end,
    is_loaded = function() return true end,
    get_asset_info = function() return { rotation = 0 } end,
    stop_all_prefetch = function() end,
    ensure_audio_pooled = function(path)
        return { has_audio = true, audio_sample_rate = 48000 }
    end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
}

-- Mock logger
package.loaded["core.logger"] = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Configurable video: maps frame → {clip_id, rotation} or nil (gap)
local video_map = {}
local function set_video_map(map) video_map = map end

-- Mock Renderer
package.loaded["core.renderer"] = {
    get_sequence_info = function(seq_id)
        return {
            fps_num = 24, fps_den = 1,
            kind = "timeline", name = "Test Seq",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function(seq, frame, ctx_id)
        local entry = video_map[frame]
        if entry then
            return "frame_handle_" .. frame, {
                clip_id = entry.clip_id or "clip1",
                media_path = entry.media_path or "/test.mov",
                source_frame = entry.source_frame or frame,
                rotation = entry.rotation or 0,
            }
        end
        -- Default: clip1 for frames 0-99, gap otherwise
        if frame >= 0 and frame < 100 then
            return "frame_handle_" .. frame, {
                clip_id = "clip1",
                media_path = "/test.mov",
                source_frame = frame,
                rotation = 0,
            }
        end
        return nil, nil
    end,
}

-- Configurable audio: maps frame → sources list or empty
local audio_sources_map = {}

-- Mock Mixer
package.loaded["core.mixer"] = {
    resolve_audio_sources = function(seq, frame, fps_num, fps_den, mc)
        local entry = audio_sources_map[frame]
        if entry then return entry.sources, entry.clip_ids end
        -- Default: one audio clip for frames 0-99
        if frame >= 0 and frame < 100 then
            return {
                { path = "/test.mov", source_offset_us = 0, seek_us = 0,
                  speed_ratio = 1.0, volume = 1.0,
                  duration_us = 4166666, clip_start_us = 0,
                  clip_end_us = 4166666, clip_id = "aclip1" },
            }, { aclip1 = true }
        end
        return {}, {}
    end,
}

-- Mock Sequence model
local mock_sequence = { id = "seq1" }
package.loaded["models.sequence"] = {
    load = function(id) return mock_sequence end,
}

-- Mock audio_playback
local function make_mock_audio()
    return {
        session_initialized = true,
        playing = false,
        has_audio = false,
        max_media_time_us = 10000000,
        _time_us = 0,

        is_ready = function() return true end,
        get_time_us = function(self_or_nothing)
            -- Handle both module-style and method-style calls
            if type(self_or_nothing) == "table" then
                return self_or_nothing._time_us
            end
            return make_mock_audio._shared._time_us
        end,
        get_media_time_us = function() return 0 end,
        seek = function() end,
        start = function() end,
        stop = function() end,
        set_speed = function() end,
        set_max_time = function() end,
        set_audio_sources = function(sources, mc, restart_time)
            -- Track that sources were set
        end,
        latch = function() end,
        play_burst = function() end,
    }
end

-- Shared mock audio instance for get_time_us module-level calls
local mock_audio = make_mock_audio()
mock_audio.get_time_us = function() return mock_audio._time_us end

-- Mock signals (required by old playback_controller if loaded transitionally)
package.loaded["core.signals"] = {
    connect = function() end,
    emit = function() end,
}

--------------------------------------------------------------------------------
-- Load PlaybackEngine
--------------------------------------------------------------------------------
local PlaybackEngine = require("core.playback.playback_engine")

--------------------------------------------------------------------------------
-- Test Helper: create engine with tracking callbacks
--------------------------------------------------------------------------------

local function make_engine(opts)
    opts = opts or {}
    local log = {
        frames_shown = {},
        gaps_shown = 0,
        rotations = {},
        positions = {},
    }

    local engine = PlaybackEngine.new({
        media_context_id = opts.context_id or "test_ctx",
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
    assert(not ok, "missing media_context_id should assert")
    print("  missing context_id: asserts ok")

    ok, _ = pcall(PlaybackEngine.new, {
        media_context_id = "x",
        on_show_frame = function() end,
        on_show_gap = function() end,
        on_set_rotation = function() end,
        -- missing on_position_changed
    })
    assert(not ok, "missing on_position_changed should assert")
    print("  missing callback: asserts ok")
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
    print("  ok")
end

-- ─── Test 3: play → tick advances → stop ───
print("\n--- play/tick/stop ---")
do
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:play()
    assert(engine:is_playing(), "should be playing")
    assert(engine.direction == 1, "forward")
    assert(engine.speed == 1, "1x")

    -- Pump one tick: frame-based advance (no audio)
    pump_tick()
    assert(engine:get_position() == 1, "advanced to frame 1, got " .. engine:get_position())
    assert(#log.frames_shown > 0, "frame was displayed")

    engine:stop()
    assert(not engine:is_playing(), "should be stopped")
    assert(engine.direction == 0, "direction reset")
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

-- ─── Test 5: boundary stop in play mode ───
print("\n--- boundary stop (play mode) ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 5)
    engine:set_position_silent(3)
    engine._last_committed_frame = 3

    engine:play()
    -- First tick: advance 3→4, hit boundary (4 >= total_frames-1), stop
    pump_tick()
    assert(not engine:is_playing(), "stopped at boundary")
    assert(engine:get_position() == 4, "parked at last frame")
    assert(not engine.latched, "play mode doesn't latch")
    print("  ok")
end

-- ─── Test 6: boundary latch in shuttle mode + unlatch ───
print("\n--- boundary latch (shuttle mode) ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 5)
    engine:set_position_silent(3)
    engine._last_committed_frame = 3

    engine:shuttle(1)  -- forward shuttle
    -- First tick: advance 3→4, hit boundary (4 >= 4), latch
    pump_tick()
    assert(engine:is_playing(), "still playing (latched)")
    assert(engine.latched, "latched at boundary")
    assert(engine.latched_boundary == "end", "latched at end")
    assert(engine:get_position() == 4, "at last frame")

    -- Same direction while latched → no-op
    engine:shuttle(1)
    assert(engine.latched, "still latched")

    -- Opposite direction → unlatch
    engine:shuttle(-1)
    assert(not engine.latched, "unlatched")
    assert(engine.direction == -1, "reversed")
    assert(engine.speed == 1, "1x after unlatch")
    print("  ok")
end

-- ─── Test 7: audio following (video follows audio time) ───
print("\n--- audio following ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Set up audio ownership with mock audio
    PlaybackEngine.init_audio(mock_audio)
    engine:activate_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true

    engine:play()
    -- Simulate audio at frame 10 (time = 10 * 1000000 / 24 = 416666us)
    mock_audio._time_us = 416666
    pump_tick()
    local pos = engine:get_position()
    -- audio frame = floor(416666 * 24 / 1000000) = floor(9.999984) = 9
    -- (rounding is inherent in integer frame math)
    assert(pos >= 9 and pos <= 10,
        "audio following: pos=" .. pos .. " expected ~10")

    engine:stop()
    mock_audio.playing = false
    mock_audio.has_audio = false
    PlaybackEngine.init_audio(nil)
    print("  ok")
end

-- ─── Test 8: stuckness detection → frame-based advance ───
print("\n--- stuckness detection ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    PlaybackEngine.init_audio(mock_audio)
    engine:activate_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true

    engine:play()

    -- First tick: audio at frame 5
    mock_audio._time_us = 5 * 1000000 / 24
    pump_tick()
    local pos1 = engine:get_position()

    -- Second tick: audio STUCK at same time
    pump_tick()
    local pos2 = engine:get_position()
    -- Should advance frame-based (pos1 + 1) since audio is stuck
    assert(pos2 > pos1,
        "stuckness: should advance frame-based, pos1=" .. pos1 .. " pos2=" .. pos2)

    engine:stop()
    mock_audio.playing = false
    mock_audio.has_audio = false
    PlaybackEngine.init_audio(nil)
    print("  ok")
end

-- ─── Test 9: gap display ───
print("\n--- gap display ---")
do
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 200)

    -- Seek to gap (frame 150, default video_map returns nil for >= 100)
    engine:seek(150)
    assert(log.gaps_shown > 0, "gap callback fired")
    print("  ok")
end

-- ─── Test 10: clip switch triggers rotation callback ───
print("\n--- clip switch + rotation ---")
do
    -- Set up two clips with different rotations
    set_video_map({
        [10] = { clip_id = "clipA", rotation = 0, source_frame = 10 },
        [11] = { clip_id = "clipA", rotation = 0, source_frame = 11 },
        [12] = { clip_id = "clipB", rotation = 90, source_frame = 0 },
    })

    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    -- Seek to clipA
    engine:seek(10)
    assert(#log.rotations == 1, "first clip → rotation callback")
    assert(log.rotations[1] == 0, "clipA rotation=0")

    -- Seek to clipB (different clip_id → rotation callback)
    engine:seek(12)
    assert(#log.rotations == 2, "clip switch → rotation callback")
    assert(log.rotations[2] == 90, "clipB rotation=90")

    -- Reset video map
    set_video_map({})
    print("  ok")
end

-- ─── Test 11: seek while playing ───
print("\n--- seek while playing ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:play()
    pump_tick()
    assert(engine:is_playing(), "playing before seek")

    engine:seek(50)
    assert(engine:is_playing(), "still playing after seek")
    assert(engine:get_position() == 50, "seeked to 50")

    engine:stop()
    print("  ok")
end

-- ─── Test 12: seek while stopped (parked) ───
print("\n--- seek while stopped ---")
do
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:seek(25)
    assert(engine:get_position() == 25, "seeked to 25")
    assert(#log.frames_shown > 0, "frame displayed on seek")
    assert(not engine:is_playing(), "still stopped")

    -- Redundant seek to same frame → skip
    local count_before = #log.frames_shown
    engine:seek(25)
    assert(#log.frames_shown == count_before, "redundant seek skipped")
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

    engine:slow_play(-1)
    assert(engine:is_playing(), "playing")
    assert(engine.speed == 0.5, "0.5x")
    assert(engine.direction == -1, "reverse")
    assert(engine.transport_mode == "shuttle", "shuttle mode for slow_play")

    engine:stop()
    print("  ok")
end

-- ─── Test 15: tick generation prevents stale callbacks ───
print("\n--- tick generation ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:play()
    assert(#timer_callbacks == 1, "one timer scheduled")

    -- Stop invalidates the generation
    engine:stop()

    -- Pump the stale callback — should be no-op
    local pos_before = engine:get_position()
    pump_tick()
    assert(engine:get_position() == pos_before, "stale tick was no-op")
    assert(not engine:is_playing(), "still stopped")
    print("  ok")
end

-- ─── Test 16: reverse shuttle → latch at start boundary ───
print("\n--- reverse latch at start ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)
    engine:set_position_silent(1)
    engine._last_committed_frame = 1

    engine:shuttle(-1)  -- reverse
    -- First tick: advance 1→0, hit start boundary (dir<0, pos<=0), latch
    pump_tick()
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
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 1)

    assert(engine.total_frames == 1, "total_frames=1")

    -- Play → immediately hit boundary at frame 0 (already there)
    engine:play()
    pump_tick()
    assert(not engine:is_playing(), "stopped (only 1 frame)")
    assert(engine:get_position() == 0, "at frame 0")
    print("  ok")
end

-- ─── Test 26: play when already playing → no-op ───
print("\n--- play when already playing ---")
do
    local engine, _ = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:play()
    local gen_before = engine._tick_generation
    local timer_count_before = #timer_callbacks

    engine:play()  -- should be no-op
    assert(engine._tick_generation == gen_before, "generation unchanged")
    -- No additional timer scheduled
    assert(#timer_callbacks == timer_count_before, "no extra timer")

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
    local engine, log = make_engine()
    clear_timers()
    engine:load_sequence("seq1", 100)

    engine:seek(50)
    engine:seek(0)
    assert(engine:get_position() == 0, "at frame 0")
    assert(#log.frames_shown >= 2, "frames displayed for both seeks")
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

print("\n✅ test_playback_engine.lua passed")
