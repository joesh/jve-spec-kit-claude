#!/usr/bin/env luajit
--- Test TMB-based audio mix path (decode_mix_and_send_to_sse + apply_mix).
--
-- Verifies:
-- - Pre-mixed PCM fetch from TMB and push to SSE
-- - send_mix_params_to_tmb resolves solo/mute into effective volumes
-- - Dedup (same pb_start skipped)
-- - apply_mix hot-swap vs cold-swap
-- - apply_mix calls send_mix_params_to_tmb on both paths
--
-- Uses real FFI for float arrays to verify actual PCM push.
--
-- @file test_audio_mix_tmb.lua

require('test_env')
local ffi = require("ffi")

print("=== test_audio_mix_tmb.lua ===")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

-- Track all calls for verification
local pcm_release_calls = {}
local sse_push_calls = {}
local sse_reset_calls = 0
local sse_set_target_calls = {}
local aop_start_calls = 0
local aop_stop_calls = 0
local aop_flush_calls = 0

-- TMB_SET_AUDIO_MIX_PARAMS call tracking
local mix_params_calls = {}

-- TMB_GET_MIXED_AUDIO: tracks calls and supports static or function responses
local get_mixed_audio_calls = {}
local mixed_audio_response = nil  -- static value or function(t0, t1)

-- SSE.CURRENT_TIME_US: configurable for extension tests
local mock_sse_current_time = 0

local function reset_mocks()
    pcm_release_calls = {}
    sse_push_calls = {}
    sse_reset_calls = 0
    sse_set_target_calls = {}
    aop_start_calls = 0
    aop_stop_calls = 0
    aop_flush_calls = 0
    mix_params_calls = {}
    get_mixed_audio_calls = {}
    mixed_audio_response = nil
    mock_sse_current_time = 0
end

--- Create a mock PCM chunk with known float data.
-- @param frames number of frames
-- @param channels number of channels
-- @param start_us start time in microseconds
-- @param fill_value number: constant value to fill all samples
-- @return table: mock PCM chunk
local function make_pcm(frames, channels, start_us, fill_value)
    local n = frames * channels
    local buf = ffi.new("float[?]", n)
    for i = 0, n - 1 do
        buf[i] = fill_value
    end
    return {
        _buf = buf,
        _frames = frames,
        _start_us = start_us,
        _channels = channels,
    }
end

-- Mock qt_constants
local mock_sse = { _name = "mock_sse" }
local mock_aop = { _name = "mock_aop" }

package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        -- Legacy per-track API (still available but not used by audio_playback)
        TMB_GET_TRACK_AUDIO = function()
            return nil
        end,
        -- New autonomous mix API
        TMB_SET_AUDIO_MIX_PARAMS = function(tmb, params, sr, ch)
            mix_params_calls[#mix_params_calls + 1] = {
                params = params, sample_rate = sr, channels = ch,
            }
        end,
        TMB_GET_MIXED_AUDIO = function(tmb, t0, t1)
            get_mixed_audio_calls[#get_mixed_audio_calls + 1] = { t0 = t0, t1 = t1 }
            if type(mixed_audio_response) == "function" then
                return mixed_audio_response(t0, t1)
            end
            return mixed_audio_response
        end,
        PCM_INFO = function(pcm)
            return { frames = pcm._frames, start_time_us = pcm._start_us }
        end,
        PCM_DATA_PTR = function(pcm)
            return pcm._buf
        end,
        PCM_RELEASE = function(pcm)
            pcm_release_calls[#pcm_release_calls + 1] = pcm
        end,
    },
    SSE = {
        CREATE = function() return mock_sse end,
        CLOSE = function() end,
        RESET = function()
            sse_reset_calls = sse_reset_calls + 1
        end,
        SET_TARGET = function(sse, t, speed, mode)
            sse_set_target_calls[#sse_set_target_calls + 1] = {
                t = t, speed = speed, mode = mode,
            }
        end,
        PUSH_PCM = function(sse, buf, frames, start_us)
            -- Copy float data for verification (buf is ffi-owned, may be GC'd)
            local data = {}
            for i = 0, frames * 2 - 1 do  -- stereo
                data[i + 1] = buf[i]
            end
            sse_push_calls[#sse_push_calls + 1] = {
                frames = frames,
                start_us = start_us,
                data = data,
            }
        end,
        RENDER_ALLOC = function(sse, frames) return ffi.new("float[?]", frames * 2), 0 end,
        CURRENT_TIME_US = function() return mock_sse_current_time end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
    },
    AOP = {
        OPEN = function() return mock_aop end,
        CLOSE = function() end,
        START = function() aop_start_calls = aop_start_calls + 1 end,
        STOP = function() aop_stop_calls = aop_stop_calls + 1 end,
        FLUSH = function() aop_flush_calls = aop_flush_calls + 1 end,
        PLAYHEAD_US = function() return 0 end,
        BUFFERED_FRAMES = function() return 0 end,
        WRITE_F32 = function() end,
        HAD_UNDERRUN = function() return false end,
        CLEAR_UNDERRUN = function() end,
    },
}

-- Mock timer
_G.qt_create_single_shot_timer = function() end

-- Mock logger
package.loaded["core.logger"] = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Mock project_generation
package.loaded["core.project_generation"] = {
    current = function() return 1 end,
    check = function() end,
}

local audio_playback = require("core.media.audio_playback")

local CHANNELS = 2
local SAMPLE_RATE = 48000

--- Init session for tests.
local function init_test_session()
    audio_playback.init_session(SAMPLE_RATE, CHANNELS)
end

--- Teardown between tests.
local function teardown()
    if audio_playback.session_initialized then
        audio_playback.shutdown_session()
    end
    -- Force reload fresh state
    package.loaded["core.media.audio_playback"] = nil
    audio_playback = require("core.media.audio_playback")
end

--- Tolerance check for float comparison.
local function approx(a, b, eps)
    eps = eps or 0.0001
    return math.abs(a - b) < eps
end

--------------------------------------------------------------------------------
-- F5: decode_mix_and_send_to_sse tests (now fetches pre-mixed from TMB)
--------------------------------------------------------------------------------

print("\n--- F5.1: pre-mixed PCM pushed to SSE ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    -- TMB returns pre-mixed 100 frames of value 0.5, starting at current time
    mixed_audio_response = make_pcm(100, CHANNELS, 5000000, 0.5)

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 1, string.format(
        "Expected 1 SSE push, got %d", #sse_push_calls))
    assert(sse_push_calls[1].frames == 100, string.format(
        "Expected 100 frames, got %d", sse_push_calls[1].frames))

    -- Verify sample values passed through unchanged
    for i = 1, 100 * CHANNELS do
        assert(approx(sse_push_calls[1].data[i], 0.5), string.format(
            "Sample[%d] should be 0.5, got %f", i, sse_push_calls[1].data[i]))
    end

    -- PCM should be released
    assert(#pcm_release_calls == 1, "PCM should be released after push")

    print("  pre-mixed PCM push passed")
end

print("\n--- F5.2: nil PCM → no SSE push ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    mixed_audio_response = nil  -- gap

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 0, string.format(
        "Expected 0 SSE pushes (nil PCM), got %d", #sse_push_calls))

    print("  nil PCM → no push passed")
end

print("\n--- F5.3: threshold refill skips when enough audio ahead ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    -- Return 2s of audio starting at current position (covers MIX_REFILL_AT threshold)
    local two_sec_frames = SAMPLE_RATE * 2  -- 96000 frames = 2 seconds
    mixed_audio_response = make_pcm(two_sec_frames, CHANNELS, 5000000, 0.5)

    -- First call: should push (cold start, no audio ahead)
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, "First call should push")

    -- Second call: 2s ahead > 500ms threshold → should skip
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, string.format(
        "Second call should skip (2s > 500ms threshold), got %d pushes", #sse_push_calls))

    print("  threshold refill dedup passed")
end

print("\n--- F5.3b: refill extends from old_end, not current_us (pop-free) ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(20000000)  -- 20s
    audio_playback.media_time_us = 5000000  -- start at 5s
    audio_playback.max_media_time_us = 20000000

    -- Initial fetch returns 2s of value 0.3 starting at 5s
    mixed_audio_response = function(t0, t1)
        -- Return PCM starting at t0, length = requested range
        local dur_us = t1 - t0
        local frames = math.floor(dur_us * SAMPLE_RATE / 1000000)
        if frames <= 0 then return nil end
        return make_pcm(frames, CHANNELS, t0, 0.3)
    end

    -- First call: cold start, pushes initial chunk
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, "Initial fetch should push to SSE")
    assert(#get_mixed_audio_calls == 1, "Initial fetch should call TMB once")

    -- Verify initial fetch starts at current_us (5s)
    assert(get_mixed_audio_calls[1].t0 == 5000000, string.format(
        "Initial fetch t0 should be 5000000, got %d", get_mixed_audio_calls[1].t0))

    -- Simulate time advancing to 6.6s (remaining = 7s - 6.6s = 400ms < 500ms threshold)
    audio_playback.media_time_us = 6600000
    mock_sse_current_time = 6500000  -- SSE render pos at 6.5s

    -- Refill should request [old_end=7s, current+2s=8.6s], NOT [6.6s, 8.6s]
    audio_playback.decode_mix_and_send_to_sse()
    assert(#get_mixed_audio_calls == 2, string.format(
        "Refill should call TMB again, got %d calls", #get_mixed_audio_calls))

    -- KEY ASSERTION: refill starts from old buffer end, not from current_us
    local refill_t0 = get_mixed_audio_calls[2].t0
    assert(refill_t0 == 7000000, string.format(
        "Refill t0 should be 7000000 (old_end), got %d — fetching from current_us causes pops",
        refill_t0))

    -- Combined push should start before SSE render pos (preserves WSOLA continuity)
    assert(#sse_push_calls == 2, "Refill should push combined buffer to SSE")
    assert(sse_push_calls[2].start_us <= mock_sse_current_time, string.format(
        "Combined push start (%d) should be <= SSE render pos (%d)",
        sse_push_calls[2].start_us, mock_sse_current_time))

    -- Combined push should have MORE frames than just the new audio
    -- (old audio preserved + new audio appended)
    local new_only_frames = math.floor(1600000 * SAMPLE_RATE / 1000000)  -- 8.6s-7s = 1.6s
    assert(sse_push_calls[2].frames > new_only_frames, string.format(
        "Combined buffer (%d frames) should exceed new-only (%d frames)",
        sse_push_calls[2].frames, new_only_frames))

    print("  refill extends from old_end passed")
end

print("\n--- F5.3c: combined buffer preserves old audio samples ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(20000000)
    audio_playback.media_time_us = 0
    audio_playback.max_media_time_us = 20000000

    -- Initial fetch: value 0.7, extension: value 0.2 (distinct values to verify ordering)
    local call_count = 0
    mixed_audio_response = function(t0, t1)
        call_count = call_count + 1
        local dur_us = t1 - t0
        local frames = math.floor(dur_us * SAMPLE_RATE / 1000000)
        if frames <= 0 then return nil end
        if call_count == 1 then
            return make_pcm(frames, CHANNELS, t0, 0.7)  -- initial
        else
            return make_pcm(frames, CHANNELS, t0, 0.2)  -- extension
        end
    end

    -- Initial push
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, "Initial push")

    -- Verify initial audio has value 0.7
    assert(approx(sse_push_calls[1].data[1], 0.7), string.format(
        "Initial audio should be 0.7, got %f", sse_push_calls[1].data[1]))

    -- Advance time to trigger refill (remaining < 500ms)
    audio_playback.media_time_us = 1600000  -- 1.6s in, remaining = 2s - 1.6s = 400ms
    mock_sse_current_time = 1500000  -- SSE at 1.5s

    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 2, "Refill should push")

    -- Combined buffer: first samples should be from OLD audio (0.7), not new (0.2)
    -- This proves old audio is preserved at the SSE render position → no WSOLA pop
    assert(approx(sse_push_calls[2].data[1], 0.7), string.format(
        "Combined buffer start should preserve old audio (0.7), got %f — WSOLA pop risk!",
        sse_push_calls[2].data[1]))

    -- Last samples should be from NEW audio (0.2)
    local last_idx = sse_push_calls[2].frames * CHANNELS
    assert(approx(sse_push_calls[2].data[last_idx], 0.2), string.format(
        "Combined buffer end should be new audio (0.2), got %f",
        sse_push_calls[2].data[last_idx]))

    print("  combined buffer preserves old audio passed")
end

--------------------------------------------------------------------------------
-- F5.4: send_mix_params_to_tmb resolves solo/mute correctly
--------------------------------------------------------------------------------

print("\n--- F5.4: send_mix_params_to_tmb solo/mute resolution ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = true },
        { track_index = 2, volume = 0.8, muted = false, soloed = false },
    }, 0)

    -- apply_mix calls send_mix_params_to_tmb which calls TMB_SET_AUDIO_MIX_PARAMS
    assert(#mix_params_calls >= 1, "Should have called TMB_SET_AUDIO_MIX_PARAMS")
    local last_call = mix_params_calls[#mix_params_calls]
    assert(#last_call.params == 2, "Should have 2 params")
    -- Track 1: soloed, volume=1.0 → effective=1.0
    assert(last_call.params[1].track_index == 1)
    assert(approx(last_call.params[1].volume, 1.0), string.format(
        "Track 1 volume should be 1.0 (soloed), got %f", last_call.params[1].volume))
    -- Track 2: not soloed → effective=0
    assert(last_call.params[2].track_index == 2)
    assert(approx(last_call.params[2].volume, 0.0), string.format(
        "Track 2 volume should be 0.0 (not soloed), got %f", last_call.params[2].volume))

    print("  solo resolution passed")
end

print("\n--- F5.5: send_mix_params_to_tmb mute resolution ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = true, soloed = false },
        { track_index = 2, volume = 0.5, muted = false, soloed = false },
    }, 0)

    assert(#mix_params_calls >= 1, "Should have called TMB_SET_AUDIO_MIX_PARAMS")
    local last_call = mix_params_calls[#mix_params_calls]
    -- Track 1: muted → effective=0
    assert(approx(last_call.params[1].volume, 0.0), string.format(
        "Track 1 volume should be 0.0 (muted), got %f", last_call.params[1].volume))
    -- Track 2: not muted → effective=0.5
    assert(approx(last_call.params[2].volume, 0.5), string.format(
        "Track 2 volume should be 0.5, got %f", last_call.params[2].volume))

    print("  mute resolution passed")
end

--------------------------------------------------------------------------------
-- F6: apply_mix hot-swap vs cold-swap tests
--------------------------------------------------------------------------------

print("\n--- F6.1: hot swap (volume change only) → no SSE reset ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- Initial: track 1 at volume 1.0
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    sse_reset_calls = 0
    local initial_params_calls = #mix_params_calls

    -- Hot swap: same track, different volume
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 0.5, muted = false, soloed = false },
    }, 1000000)

    assert(sse_reset_calls == 0, string.format(
        "Hot swap should NOT reset SSE, got %d resets", sse_reset_calls))

    -- Verify TMB_SET_AUDIO_MIX_PARAMS was called for the hot swap
    assert(#mix_params_calls > initial_params_calls,
        "Hot swap should call TMB_SET_AUDIO_MIX_PARAMS")

    -- Verify new volume is stored
    assert(audio_playback._mix_params[1].volume == 0.5,
        "Volume should be updated to 0.5")

    print("  hot swap (volume) → no reset passed")
end

print("\n--- F6.2: hot swap (mute toggle) → no SSE reset ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    sse_reset_calls = 0

    -- Toggle mute: same track set, different mute state
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = true, soloed = false },
    }, 1000000)

    assert(sse_reset_calls == 0,
        "Mute toggle should NOT reset SSE")
    assert(audio_playback._mix_params[1].muted == true,
        "Muted should be updated to true")

    print("  hot swap (mute) → no reset passed")
end

print("\n--- F6.3: cold swap (track set change) → SSE reset ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- Initial: 1 track
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    sse_reset_calls = 0

    -- Cold swap: different track set (added track 2)
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 1000000)

    assert(sse_reset_calls > 0, string.format(
        "Track set change should reset SSE, got %d resets", sse_reset_calls))

    print("  cold swap (track added) → reset passed")
end

print("\n--- F6.4: cold swap (track removed) → SSE reset ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- Initial: 2 tracks
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 0)
    sse_reset_calls = 0

    -- Cold swap: remove track 2
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 2000000)

    assert(sse_reset_calls > 0,
        "Track removal should reset SSE")

    print("  cold swap (track removed) → reset passed")
end

print("\n--- F6.5: cold swap (track index change) → SSE reset ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- Initial: track 1
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    sse_reset_calls = 0

    -- Cold swap: track 2 instead of track 1 (different track)
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 3000000)

    assert(sse_reset_calls > 0,
        "Track index change should reset SSE")

    print("  cold swap (track index change) → reset passed")
end

print("\n--- F6.6: cold swap while playing → stop + restart ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000

    -- Simulate playing state
    audio_playback.playing = true
    aop_stop_calls = 0
    aop_start_calls = 0

    -- Provide PCM for restart decode
    mixed_audio_response = make_pcm(100, CHANNELS, 0, 0.5)

    -- Cold swap (track added) while playing → must stop and restart
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 5000000)

    assert(aop_stop_calls > 0, "Cold swap while playing must stop AOP")
    assert(aop_start_calls > 0, "Cold swap while playing must restart AOP")
    assert(audio_playback.playing == true, "Should resume playing after cold swap")

    print("  cold swap while playing → stop + restart passed")
end

print("\n--- F6.7: apply_mix with empty params → has_audio = false ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- First: set some tracks
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    assert(audio_playback.has_audio == true, "Should have audio after apply_mix")

    -- Clear: empty params
    audio_playback.apply_mix(mock_tmb, {}, 1000000)
    assert(audio_playback.has_audio == false, "Should not have audio after empty apply_mix")

    print("  empty params → has_audio=false passed")
end

print("\n--- F6.8: apply_mix calls TMB_SET_AUDIO_MIX_PARAMS on both paths ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- Cold path
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    local cold_calls = #mix_params_calls
    assert(cold_calls >= 1, "Cold path should call TMB_SET_AUDIO_MIX_PARAMS")

    -- Hot path (same track, different volume)
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 0.5, muted = false, soloed = false },
    }, 1000000)
    assert(#mix_params_calls > cold_calls,
        "Hot path should also call TMB_SET_AUDIO_MIX_PARAMS")

    print("  both paths call TMB_SET_AUDIO_MIX_PARAMS passed")
end

--------------------------------------------------------------------------------
-- Test 9: refresh_mix_volumes — updates params and invalidates SSE buffer
--------------------------------------------------------------------------------
do
    print("\n--- Test 9: refresh_mix_volumes updates params and invalidates SSE ---")
    teardown()
    reset_mocks()
    audio_playback = require("core.media.audio_playback")
    audio_playback.init_session(48000, 2)

    local mock_tmb = "test_tmb"
    local pcm = make_pcm(96000, 2, 0, 0.5)
    mixed_audio_response = pcm

    -- Set up initial mix (creates SSE buffer via cold fetch)
    audio_playback.set_max_time(10000000)  -- 10s playback range
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)

    reset_mocks()

    -- refresh_mix_volumes with muted track
    audio_playback.refresh_mix_volumes({
        { track_index = 1, volume = 1.0, muted = true, soloed = false },
    })

    -- Should have sent mix params to TMB with volume=0 (muted)
    assert(#mix_params_calls >= 1,
        "refresh_mix_volumes must call TMB_SET_AUDIO_MIX_PARAMS")
    local resolved = mix_params_calls[#mix_params_calls].params
    assert(#resolved == 1, "Should have 1 track param")
    assert(resolved[1].volume == 0,
        "Muted track should resolve to volume=0, got " .. tostring(resolved[1].volume))

    -- has_audio should still be true (1 track, even if muted)
    assert(audio_playback.has_audio == true,
        "has_audio should be true when tracks exist (even muted)")

    -- Next decode_mix_and_send_to_sse should do cold fetch (SSE invalidated)
    mixed_audio_response = pcm
    audio_playback.decode_mix_and_send_to_sse()
    assert(#get_mixed_audio_calls >= 1,
        "SSE buffer invalidated → cold fetch should call TMB_GET_MIXED_AUDIO")

    print("  refresh_mix_volumes mute passed")
end

--------------------------------------------------------------------------------
-- Test 10: refresh_mix_volumes — solo resolution
--------------------------------------------------------------------------------
do
    print("\n--- Test 10: refresh_mix_volumes solo resolution ---")
    teardown()
    reset_mocks()
    audio_playback = require("core.media.audio_playback")
    audio_playback.init_session(48000, 2)

    local mock_tmb = "test_tmb"
    local pcm = make_pcm(96000, 2, 0, 0.5)
    mixed_audio_response = pcm

    -- Set up initial 2-track mix
    audio_playback.set_max_time(10000000)  -- 10s playback range
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
        { track_index = 2, volume = 0.8, muted = false, soloed = false },
    }, 0)

    reset_mocks()

    -- Solo track 1 → track 2 should get volume 0
    audio_playback.refresh_mix_volumes({
        { track_index = 1, volume = 1.0, muted = false, soloed = true },
        { track_index = 2, volume = 0.8, muted = false, soloed = false },
    })

    assert(#mix_params_calls >= 1,
        "refresh_mix_volumes must call TMB_SET_AUDIO_MIX_PARAMS")
    local resolved = mix_params_calls[#mix_params_calls].params
    assert(#resolved == 2, "Should have 2 track params")
    assert(resolved[1].volume == 1.0,
        "Soloed track should keep volume=1.0, got " .. tostring(resolved[1].volume))
    assert(resolved[2].volume == 0,
        "Non-soloed track should resolve to volume=0, got " .. tostring(resolved[2].volume))

    print("  refresh_mix_volumes solo passed")
end

--------------------------------------------------------------------------------
-- Test 11: refresh_mix_volumes — assert on nil session
--------------------------------------------------------------------------------
do
    print("\n--- Test 11: refresh_mix_volumes asserts without session ---")
    teardown()
    reset_mocks()
    audio_playback = require("core.media.audio_playback")
    -- Do NOT init session

    local ok, err = pcall(function()
        audio_playback.refresh_mix_volumes({
            { track_index = 1, volume = 1.0, muted = false, soloed = false },
        })
    end)
    assert(not ok, "Should assert when session not initialized")
    assert(err:find("session not initialized"),
        "Error should mention session, got: " .. tostring(err))

    print("  refresh_mix_volumes session assert passed")
end

--------------------------------------------------------------------------------
-- Test 12: refresh_mix_volumes — assert on non-table mix_params
--------------------------------------------------------------------------------
do
    print("\n--- Test 12: refresh_mix_volumes asserts on bad input ---")
    teardown()
    reset_mocks()
    audio_playback = require("core.media.audio_playback")
    audio_playback.init_session(48000, 2)

    local ok, err = pcall(function()
        audio_playback.refresh_mix_volumes("not_a_table")
    end)
    assert(not ok, "Should assert on non-table mix_params")
    assert(err:find("must be a table"),
        "Error should mention table, got: " .. tostring(err))

    print("  refresh_mix_volumes bad input assert passed")
end

--------------------------------------------------------------------------------
-- G1: Reverse audio warm extension (extend_and_push with speed < 0)
--------------------------------------------------------------------------------
print("\n--- G1: reverse warm extension fetches from old_start backward ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(20000000)  -- 20s
    audio_playback.max_media_time_us = 20000000
    audio_playback.speed = -1.0  -- REVERSE

    -- Position at 10s, reverse cold fetch covers [8s, 10s]
    audio_playback.media_time_us = 10000000

    mixed_audio_response = function(t0, t1)
        local dur_us = t1 - t0
        local frames = math.floor(dur_us * SAMPLE_RATE / 1000000)
        if frames <= 0 then return nil end
        return make_pcm(frames, CHANNELS, t0, 0.4)
    end

    -- Cold fetch (reverse: [8s, 10s])
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, "Cold reverse push")
    assert(#get_mixed_audio_calls == 1, "Cold reverse fetch")
    assert(get_mixed_audio_calls[1].t0 == 8000000, string.format(
        "Reverse cold t0 should be 8000000, got %d", get_mixed_audio_calls[1].t0))
    assert(get_mixed_audio_calls[1].t1 == 10000000, string.format(
        "Reverse cold t1 should be 10000000, got %d", get_mixed_audio_calls[1].t1))

    -- Advance backward to 8.4s (remaining = 10s - 8.4s = 400ms < 500ms threshold)
    -- Wait — reverse remaining = current - start = 8.4s - 8s = 400ms < 500ms
    audio_playback.media_time_us = 8400000
    mock_sse_current_time = 8500000  -- SSE render at 8.5s

    -- Extension should now return different value to distinguish from old
    mixed_audio_response = function(t0, t1)
        local dur_us = t1 - t0
        local frames = math.floor(dur_us * SAMPLE_RATE / 1000000)
        if frames <= 0 then return nil end
        return make_pcm(frames, CHANNELS, t0, 0.9)  -- distinct value
    end

    audio_playback.decode_mix_and_send_to_sse()
    assert(#get_mixed_audio_calls == 2, string.format(
        "Refill should call TMB again, got %d", #get_mixed_audio_calls))

    -- Reverse extension: fetch_end = old start (8s), fetch_start = max(0, 8.4s-2s) = 6.4s
    local refill_t1 = get_mixed_audio_calls[2].t1
    assert(refill_t1 == 8000000, string.format(
        "Reverse refill t1 should be 8000000 (old start), got %d", refill_t1))
    local refill_t0 = get_mixed_audio_calls[2].t0
    assert(refill_t0 == 6400000, string.format(
        "Reverse refill t0 should be 6400000, got %d", refill_t0))

    -- Combined push should have happened
    assert(#sse_push_calls == 2, "Reverse refill should push combined buffer")

    -- Combined buffer: first samples are NEW (0.9), later samples are OLD (0.4)
    -- (reverse: new audio is prepended before old)
    assert(approx(sse_push_calls[2].data[1], 0.9), string.format(
        "Reverse combined start should be new audio (0.9), got %f",
        sse_push_calls[2].data[1]))

    print("  reverse warm extension passed")
end

--------------------------------------------------------------------------------
-- G2: Nil TMB response during warm extension
--------------------------------------------------------------------------------
print("\n--- G2: nil TMB during warm extension retains old buffer ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(20000000)
    audio_playback.media_time_us = 0
    audio_playback.max_media_time_us = 20000000

    -- Cold fetch succeeds with 2s of audio
    mixed_audio_response = function(t0, t1)
        local dur_us = t1 - t0
        local frames = math.floor(dur_us * SAMPLE_RATE / 1000000)
        if frames <= 0 then return nil end
        return make_pcm(frames, CHANNELS, t0, 0.6)
    end

    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, "Cold push")

    -- Advance to trigger refill
    audio_playback.media_time_us = 1600000
    mock_sse_current_time = 1500000

    -- TMB returns nil for extension (e.g. gap in next clip)
    mixed_audio_response = nil

    audio_playback.decode_mix_and_send_to_sse()

    -- No new push (extension returned nil)
    assert(#sse_push_calls == 1, string.format(
        "Nil extension should not push to SSE, got %d pushes", #sse_push_calls))

    -- Buffer state should be unchanged (still warm with old data)
    -- Verify by calling again — it should try extension again, not cold
    audio_playback.decode_mix_and_send_to_sse()
    assert(#get_mixed_audio_calls == 3, string.format(
        "Should keep trying extension (warm path), got %d TMB calls",
        #get_mixed_audio_calls))

    print("  nil TMB warm extension passed")
end

--------------------------------------------------------------------------------
-- G3: AOP underrun detection fires CLEAR_UNDERRUN
--------------------------------------------------------------------------------
print("\n--- G3: AOP underrun detected and cleared in pump_tick ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 0
    audio_playback.max_media_time_us = 10000000
    mixed_audio_response = make_pcm(96000, CHANNELS, 0, 0.5)

    -- Set up playing state for _pump_tick
    audio_playback.playing = true

    -- Track underrun calls
    local had_underrun_calls = 0
    local clear_underrun_calls = 0
    local warn_messages = {}

    -- Override mocks for this test
    local qt = package.loaded["core.qt_constants"]
    local orig_had = qt.AOP.HAD_UNDERRUN
    local orig_clear = qt.AOP.CLEAR_UNDERRUN
    qt.AOP.HAD_UNDERRUN = function()
        had_underrun_calls = had_underrun_calls + 1
        return true  -- simulate underrun
    end
    qt.AOP.CLEAR_UNDERRUN = function()
        clear_underrun_calls = clear_underrun_calls + 1
    end

    -- Override logger to capture warn calls
    local orig_warn = package.loaded["core.logger"].warn
    package.loaded["core.logger"].warn = function(component, msg)
        warn_messages[#warn_messages + 1] = { component = component, msg = msg }
    end

    -- Call _pump_tick (needs frames_needed > 0 to enter the underrun check)
    audio_playback._pump_tick()

    -- Restore mocks
    qt.AOP.HAD_UNDERRUN = orig_had
    qt.AOP.CLEAR_UNDERRUN = orig_clear
    package.loaded["core.logger"].warn = orig_warn
    audio_playback.playing = false

    -- Verify underrun was detected and cleared
    assert(had_underrun_calls >= 1, string.format(
        "HAD_UNDERRUN should be called, got %d calls", had_underrun_calls))
    assert(clear_underrun_calls >= 1, string.format(
        "CLEAR_UNDERRUN must be called after underrun detected, got %d calls",
        clear_underrun_calls))

    -- Verify warn message was logged
    local found_underrun_warn = false
    for _, w in ipairs(warn_messages) do
        if w.component == "audio_playback" and w.msg:find("UNDERRUN") then
            found_underrun_warn = true
            break
        end
    end
    assert(found_underrun_warn,
        "logger.warn should log AOP UNDERRUN message")

    print("  AOP underrun detection passed")
end

--------------------------------------------------------------------------------
-- G4: Cold fetch with zero-frame PCM
--------------------------------------------------------------------------------
print("\n--- G4: cold fetch with zero-frame PCM releases and skips ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    -- TMB returns PCM with 0 frames (e.g. very short gap)
    mixed_audio_response = make_pcm(0, CHANNELS, 5000000, 0.0)

    audio_playback.decode_mix_and_send_to_sse()

    -- PCM should be released (not leaked)
    assert(#pcm_release_calls == 1, string.format(
        "Zero-frame PCM must be released, got %d releases", #pcm_release_calls))

    -- No SSE push (nothing to push)
    assert(#sse_push_calls == 0, string.format(
        "Zero-frame PCM should not push to SSE, got %d pushes", #sse_push_calls))

    -- Buffer should NOT be updated (still cold)
    -- Verify: next call should still be cold path (not warm)
    mixed_audio_response = make_pcm(96000, CHANNELS, 5000000, 0.5)
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, "Second call should cold-fetch and push")

    print("  zero-frame PCM release passed")
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------
teardown()

print("\n✅ test_audio_mix_tmb.lua passed")
