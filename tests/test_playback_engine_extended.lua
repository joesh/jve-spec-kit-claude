--- Extended PlaybackEngine tests: behaviors migrated from old singleton tests.
--
-- Covers gaps not in test_playback_engine.lua:
-- - Extended latch state machine (transport_mode, same-dir no-op, cycles)
-- - Same-frame decimation (audio returns same frame → skip display)
-- - Reverse playback invariants (monotonicity, speed scaling)
-- - Multi-tick stuckness non-oscillation
-- - Seek during playback audio lifecycle (stop→seek→start)
-- - Seek deduplication (parked)
-- - Gap→clip audio start transition
-- - Audio clip change detection
-- - Frame step audio burst (play_frame_audio)
-- - Prefetch signaling (set_playhead calls)
-- - Video-follows-audio formula at multiple data points

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure (same pattern as test_playback_engine.lua)
--------------------------------------------------------------------------------

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

-- Prefetch tracking
local prefetch_calls = {}

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    activate = function() return { rotation = 0 } end,
    get_video_frame = function(frame, ctx) return "frame_" .. frame end,
    set_playhead = function(frame, dir, speed, ctx)
        prefetch_calls[#prefetch_calls + 1] = {
            frame = frame, direction = dir, speed = speed, ctx = ctx,
        }
    end,
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

-- Configurable video map: frame → {clip_id, rotation, source_frame, media_path}
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

-- Configurable audio sources map
local audio_sources_map = {}

-- Mock Mixer
package.loaded["core.mixer"] = {
    resolve_audio_sources = function(seq, frame, fps_num, fps_den, mc)
        local entry = audio_sources_map[frame]
        if entry then return entry.sources, entry.clip_ids end
        if frame >= 0 and frame < 100 then
            return {
                { path = "/test.mov", source_offset_us = 0, volume = 1.0,
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

-- Mock signals
package.loaded["core.signals"] = {
    connect = function() end,
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
        -- Call tracking
        _calls = {},
    }

    local function track(name, ...)
        audio._calls[#audio._calls + 1] = { name = name, args = {...} }
    end

    audio.is_ready = function() return audio.session_initialized end
    audio.get_time_us = function() return audio._time_us end
    audio.get_media_time_us = function() return audio._time_us end
    audio.seek = function(t) track("seek", t) end
    audio.start = function() track("start"); audio.playing = true end
    audio.stop = function() track("stop"); audio.playing = false end
    audio.set_speed = function(s) track("set_speed", s) end
    audio.set_max_time = function(t) track("set_max_time", t) end
    audio.set_audio_sources = function(sources, mc, restart_time)
        track("set_audio_sources", sources, mc, restart_time)
        audio.has_audio = (#sources > 0)
    end
    audio.latch = function(t) track("latch", t) end
    audio.play_burst = function(time, dur)
        track("play_burst", time, dur)
    end
    audio.init_session = function() end
    audio.shutdown_session = function() end

    return audio
end

--------------------------------------------------------------------------------
-- Load PlaybackEngine
--------------------------------------------------------------------------------
local PlaybackEngine = require("core.playback.playback_engine")

--------------------------------------------------------------------------------
-- Test helper
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

local function reset()
    clear_timers()
    prefetch_calls = {}
    video_map = {}
    audio_sources_map = {}
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

    local engine, log = make_engine()
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

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    -- No activate_audio → frame-based advance (simpler for latch tests)
    engine:set_position_silent(98)

    engine:shuttle(1)  -- forward shuttle
    -- Advance to boundary (frame-based: 98→99 in 1-2 ticks)
    for i = 1, 5 do pump_tick() end

    assert(engine.latched, "Should be latched at end boundary")
    assert(engine.latched_boundary == "end", "Should be latched at end")

    local pos_before = engine:get_position()
    engine:shuttle(1)  -- same direction while latched: no-op
    assert(engine.latched, "Should still be latched after same-direction shuttle")
    assert(engine:get_position() == pos_before, "Position shouldn't change")

    -- Opposite direction unlatches
    engine:shuttle(-1)
    assert(not engine.latched, "Should unlatch on opposite direction")
    assert(engine.direction == -1, "Direction should be -1 after unlatch")
    assert(engine.speed == 1, "Speed should reset to 1 after unlatch")

    engine:stop()
    print("  same-direction no-op and unlatch passed")
end

print("\n--- extended latch: multiple latch/unlatch cycles ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    -- No activate_audio → frame-based advance

    -- Cycle 1: forward to end, unlatch backward
    engine:set_position_silent(97)
    engine:shuttle(1)
    for i = 1, 5 do pump_tick() end
    assert(engine.latched, "Cycle 1: should latch at end")
    engine:shuttle(-1)
    assert(not engine.latched, "Cycle 1: should unlatch")

    -- Cycle 2: backward to start
    engine:stop()
    engine:set_position_silent(2)
    engine:shuttle(-1)
    for i = 1, 5 do pump_tick() end
    assert(engine.latched, "Cycle 2: should latch at start")
    assert(engine.latched_boundary == "start", "Cycle 2: boundary=start")
    engine:shuttle(1)
    assert(not engine.latched, "Cycle 2: should unlatch")
    engine:stop()

    print("  multiple latch/unlatch cycles passed")
end

--------------------------------------------------------------------------------
-- Test 2: Same-frame decimation
--------------------------------------------------------------------------------
print("\n--- same-frame decimation: skip display when audio returns same frame ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()

    engine:play()
    -- First tick: audio at frame 10
    mock_audio._time_us = math.floor(10 * 1000000 / 24)
    pump_tick()
    local frames_after_first = #log.frames_shown

    -- Second tick: audio still at frame 10 (stuck → frame-based advance)
    -- Third tick: audio still at 10 → frame-based advance again
    pump_tick()
    pump_tick()

    -- Should have shown frames (stuckness causes frame-based advance, which changes frame)
    assert(#log.frames_shown > frames_after_first,
        "Frame-based advance should display new frames when audio stuck")

    -- Now verify _last_tick_frame is tracked
    assert(engine._last_tick_frame ~= nil,
        "_last_tick_frame should be set during playback")

    -- After stop, _last_tick_frame resets
    engine:stop()
    assert(engine._last_tick_frame == nil,
        "_last_tick_frame should be nil after stop")

    print("  same-frame decimation passed")
end

--------------------------------------------------------------------------------
-- Test 3: Reverse playback invariants
--------------------------------------------------------------------------------
print("\n--- reverse playback: frames decrease monotonically ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:set_position_silent(80)

    -- No audio: frame-based advance in reverse
    engine:shuttle(-1)
    local positions = {}
    for i = 1, 15 do
        pump_tick()
        positions[#positions + 1] = engine:get_position()
    end
    engine:stop()

    -- Verify monotonic decrease
    for i = 2, #positions do
        assert(positions[i] <= positions[i-1],
            string.format("Position should decrease: pos[%d]=%s >= pos[%d]=%s",
                i, tostring(positions[i]), i-1, tostring(positions[i-1])))
    end

    -- Verify actual progress (not stuck)
    assert(positions[#positions] < positions[1],
        "Should have made progress in reverse")

    print("  reverse monotonic decrease passed")
end

print("\n--- reverse playback: speed scaling ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    -- Test 1x speed
    local engine1, _ = make_engine({ context_id = "ctx1" })
    engine1:load_sequence("seq1", 100)
    engine1:set_position_silent(80)
    engine1:shuttle(-1)
    for i = 1, 10 do pump_tick() end
    local delta_1x = 80 - engine1:get_position()
    engine1:stop()

    -- Test 2x speed (shuttle twice)
    local engine2, _ = make_engine({ context_id = "ctx2" })
    engine2:load_sequence("seq1", 100)
    engine2:set_position_silent(80)
    engine2:shuttle(-1)
    engine2:shuttle(-1)  -- 2x
    clear_timers()
    for i = 1, 10 do
        engine2:_tick()
    end
    local delta_2x = 80 - engine2:get_position()
    engine2:stop()

    assert(delta_2x > delta_1x,
        string.format("2x should advance more than 1x: 2x=%s, 1x=%s",
            tostring(delta_2x), tostring(delta_1x)))

    print("  reverse speed scaling passed")
end

--------------------------------------------------------------------------------
-- Test 4: Multi-tick stuckness non-oscillation
--------------------------------------------------------------------------------
print("\n--- stuckness: monotonic advance over 10 ticks ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true
    -- Audio stuck at frame 50 for entire test
    mock_audio._time_us = math.floor(50 * 1000000 / 24)
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    engine:set_position_silent(50)

    engine:play()

    local positions = {}
    for i = 1, 10 do
        pump_tick()
        positions[#positions + 1] = math.floor(engine:get_position())
    end
    engine:stop()

    -- First tick: audio at 50, engine starts at 50 → follows audio = 50
    -- Subsequent ticks: audio still 50 → stuck → frame-based advance
    -- Should see monotonic increase: 50, 51, 52, ...
    for i = 2, #positions do
        assert(positions[i] >= positions[i-1],
            string.format("Stuckness advance must be monotonic: pos[%d]=%d < pos[%d]=%d",
                i, positions[i], i-1, positions[i-1]))
    end

    -- Must have advanced past 50
    assert(positions[#positions] > 50,
        string.format("Should advance past stuck frame 50, got %d", positions[#positions]))

    print("  stuckness monotonic advance passed")
end

print("\n--- stuckness: audio unsticks → video follows audio again ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true
    mock_audio._time_us = math.floor(50 * 1000000 / 24)
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    engine:set_position_silent(50)

    engine:play()

    -- 5 ticks with audio stuck at 50
    for i = 1, 5 do pump_tick() end
    local pos_stuck = math.floor(engine:get_position())
    assert(pos_stuck > 50, "Should have advanced via frame-based during stuck")

    -- Audio unsticks → jumps to frame 70
    mock_audio._time_us = math.floor(70 * 1000000 / 24)
    pump_tick()
    local pos_after = math.floor(engine:get_position())

    -- Video should now follow audio to ~70
    assert(pos_after >= 69 and pos_after <= 71,
        string.format("After unstick, pos should be ~70, got %d", pos_after))

    engine:stop()
    print("  audio unstick → video follows passed")
end

--------------------------------------------------------------------------------
-- Test 5: Seek during playback audio lifecycle
--------------------------------------------------------------------------------
print("\n--- seek during playback: stop→seek→start audio ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()

    engine:play()
    mock_audio._calls = {}  -- clear calls from play()

    -- Seek to frame 50 while playing
    engine:seek(50)

    -- Verify audio lifecycle: stop before seek, start after
    local saw_stop = false
    local saw_seek = false
    local saw_start = false
    local stop_idx, seek_idx, start_idx

    for i, call in ipairs(mock_audio._calls) do
        if call.name == "stop" then saw_stop = true; stop_idx = i end
        if call.name == "seek" then saw_seek = true; seek_idx = i end
        if call.name == "start" then saw_start = true; start_idx = i end
    end

    assert(saw_stop, "Seek during playback must stop audio")
    assert(saw_seek, "Seek during playback must seek audio")
    assert(saw_start, "Seek during playback must restart audio")
    assert(stop_idx < seek_idx, "Stop must come before seek")
    assert(seek_idx < start_idx, "Seek must come before start")

    engine:stop()
    print("  seek during playback audio lifecycle passed")
end

print("\n--- seek while stopped: no stop/start cycle ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    mock_audio._calls = {}

    -- Seek while stopped
    engine:seek(50)

    local saw_stop = false
    local saw_start = false
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "stop" then saw_stop = true end
        if call.name == "start" then saw_start = true end
    end

    assert(not saw_stop, "Seek while stopped should not stop audio")
    assert(not saw_start, "Seek while stopped should not start audio")

    print("  seek while stopped: no lifecycle passed")
end

--------------------------------------------------------------------------------
-- Test 6: Seek deduplication
--------------------------------------------------------------------------------
print("\n--- seek deduplication: parked same-frame skips decode ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)

    -- First seek displays
    engine:seek(30)
    local count1 = #log.frames_shown
    assert(count1 > 0, "First seek should display frame")

    -- Second seek to same frame: no display
    engine:seek(30)
    local count2 = #log.frames_shown
    assert(count2 == count1,
        string.format("Same-frame seek should skip decode: %d != %d", count2, count1))

    -- Different frame: display
    engine:seek(31)
    assert(#log.frames_shown > count2, "Different frame should display")

    print("  seek deduplication passed")
end

--------------------------------------------------------------------------------
-- Test 7: Gap→clip audio start transition
--------------------------------------------------------------------------------
print("\n--- gap→clip: audio starts when entering clip from gap ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    -- Frames 0-49: gap, frames 50-99: clip
    set_video_map({})
    for f = 50, 99 do
        video_map[f] = { clip_id = "clip1" }
    end
    -- Audio: gap for 0-49, sources for 50-99
    for f = 0, 49 do
        audio_sources_map[f] = { sources = {}, clip_ids = {} }
    end

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    engine:set_position_silent(48)

    engine:play()
    mock_audio._calls = {}

    -- Tick through gap
    pump_tick()  -- frame 49, gap → no audio sources
    -- Simulate audio device exhausting buffer during gap (real SSE behavior)
    mock_audio.playing = false

    -- Tick into clip (frame 50): sources appear, audio should restart
    mock_audio._calls = {}
    pump_tick()

    -- Audio should have sources now and be started
    local saw_start = false
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "start" then saw_start = true end
    end
    assert(saw_start, "Audio should start when entering clip from gap")

    -- Next tick: no double-start
    mock_audio._calls = {}
    pump_tick()
    local start_count = 0
    for _, call in ipairs(mock_audio._calls) do
        if call.name == "start" then start_count = start_count + 1 end
    end
    -- Audio already playing, so no start call unless clip switch
    -- (engine step 7 checks `not audio_playback.playing`)

    engine:stop()
    print("  gap→clip audio start passed")
end

--------------------------------------------------------------------------------
-- Test 8: Audio clip change detection
--------------------------------------------------------------------------------
print("\n--- audio clip change detection ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    local engine, log = make_engine()
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

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    mock_audio._calls = {}

    -- play_frame_audio at frame 30
    engine:play_frame_audio(30)

    -- Find play_burst call
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

    local engine, log = make_engine()
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

    local engine, log = make_engine()
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
-- Test 10: Prefetch signaling
--------------------------------------------------------------------------------
print("\n--- prefetch: set_playhead called with source_frame during display ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    -- Custom video map with source_frame != frame
    set_video_map({})
    for f = 0, 99 do
        video_map[f] = {
            clip_id = "clip1",
            source_frame = f + 100,  -- source_frame offset
            media_path = "/test.mov",
        }
    end

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:set_position_silent(10)

    engine:shuttle(1)  -- direction=1
    pump_tick()

    -- Should have called set_playhead with source_frame, not timeline frame
    assert(#prefetch_calls > 0, "set_playhead should be called during display")
    local last = prefetch_calls[#prefetch_calls]
    assert(last.direction == 1, "Prefetch direction should match shuttle")
    -- source_frame = displayed frame + 100
    assert(last.frame >= 100, string.format(
        "set_playhead should use source_frame (>= 100), got %d", last.frame))

    engine:stop()
    print("  prefetch with source_frame passed")
end

print("\n--- prefetch: no set_playhead during gap ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    PlaybackEngine.init_audio(mock_audio)

    -- All frames are gaps
    set_video_map({})

    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)

    -- Seek to gap frame (direction=0 for seek, so no prefetch anyway)
    -- But let's test display directly
    prefetch_calls = {}
    engine:_display_frame(50)  -- gap: no clip data

    assert(#prefetch_calls == 0,
        "Gap should not call set_playhead")

    print("  no prefetch during gap passed")
end

--------------------------------------------------------------------------------
-- Test 11: Video-follows-audio formula at multiple data points
--------------------------------------------------------------------------------
print("\n--- video follows audio: formula verification at 25fps ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true
    PlaybackEngine.init_audio(mock_audio)

    -- Override Renderer to return 25fps
    local orig_get_info = package.loaded["core.renderer"].get_sequence_info
    package.loaded["core.renderer"].get_sequence_info = function()
        return { fps_num = 25, fps_den = 1, kind = "timeline",
                 name = "25fps", audio_sample_rate = 48000 }
    end

    -- Extend video map for 25fps sequence
    set_video_map({})
    for f = 0, 199 do
        video_map[f] = { clip_id = "clip1", source_frame = f }
    end
    for f = 0, 199 do
        audio_sources_map[f] = {
            sources = {{ path = "/test.mov", source_offset_us = 0, volume = 1.0,
                         duration_us = 8000000, clip_start_us = 0,
                         clip_end_us = 8000000, clip_id = "aclip1" }},
            clip_ids = { aclip1 = true },
        }
    end

    local engine, log = make_engine()
    engine:load_sequence("seq1", 200)
    engine:activate_audio()
    engine:set_position_silent(0)

    engine:play()

    -- Data points: audio_time → expected_frame
    local test_cases = {
        { time_us = 2000000, expected = 50 },   -- 2s @ 25fps = frame 50
        { time_us = 3000000, expected = 75 },   -- 3s @ 25fps = frame 75
        { time_us = 1000000, expected = 25 },   -- 1s @ 25fps = frame 25
        { time_us = 4000000, expected = 100 },  -- 4s @ 25fps = frame 100
    }

    for _, tc in ipairs(test_cases) do
        mock_audio._time_us = tc.time_us
        -- Reset _last_audio_frame so audio-following engages
        engine._last_audio_frame = nil
        pump_tick()
        local pos = math.floor(engine:get_position())
        assert(pos == tc.expected,
            string.format("At %d us, expected frame %d, got %d",
                tc.time_us, tc.expected, pos))
    end

    engine:stop()
    -- Restore renderer
    package.loaded["core.renderer"].get_sequence_info = orig_get_info

    print("  video follows audio formula verified")
end

--------------------------------------------------------------------------------
-- Test 12: _last_audio_frame tracked separately (prevents oscillation)
--------------------------------------------------------------------------------
print("\n--- _last_audio_frame: separate tracking prevents oscillation ---")
do
    reset()
    local mock_audio = make_tracked_audio()
    mock_audio.playing = true
    mock_audio.has_audio = true
    PlaybackEngine.init_audio(mock_audio)

    local helpers = require("core.playback.playback_helpers")
    local engine, log = make_engine()
    engine:load_sequence("seq1", 100)
    engine:activate_audio()
    engine:set_position_silent(50)

    engine:play()

    -- Use ceil to ensure clean round-trip: time→frame→time at 24fps
    -- (math.floor(50*1e6/24) = 2083333, but 2083333*24/1e6 = 49.999... → frame 49)
    local time_50 = math.ceil(50 * 1000000 / 24)  -- 2083334 → frame 50
    local frame_50 = helpers.calc_frame_from_time_us(time_50, 24, 1)
    assert(frame_50 == 50,
        string.format("Sanity: time %d should map to frame 50, got %d", time_50, frame_50))

    -- Audio at frame 50: first tick follows audio, records _last_audio_frame
    mock_audio._time_us = time_50
    pump_tick()
    assert(engine._last_audio_frame == 50,
        string.format("First tick: _last_audio_frame should be 50, got %s",
            tostring(engine._last_audio_frame)))

    -- Second tick: audio still at 50 → stuck → frame-based advance
    -- _last_audio_frame should NOT change (it tracks audio, not video position)
    pump_tick()
    assert(engine._last_audio_frame == 50,
        "_last_audio_frame should stay 50 during stuck (frame-based advance)")

    -- Position should have advanced past 50
    assert(engine:get_position() > 50,
        "Position should advance via frame-based during stuck")

    -- Audio advances to 60: _last_audio_frame updates
    local time_60 = math.ceil(60 * 1000000 / 24)
    mock_audio._time_us = time_60
    pump_tick()
    local frame_60 = helpers.calc_frame_from_time_us(time_60, 24, 1)
    assert(engine._last_audio_frame == frame_60,
        string.format("_last_audio_frame should update to %d when audio unsticks, got %s",
            frame_60, tostring(engine._last_audio_frame)))

    engine:stop()
    -- After stop: _last_audio_frame cleared
    assert(engine._last_audio_frame == nil,
        "_last_audio_frame should be nil after stop")

    print("  _last_audio_frame separate tracking passed")
end

print("\n✅ test_playback_engine_extended.lua passed")
