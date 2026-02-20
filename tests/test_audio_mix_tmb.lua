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

-- What TMB_GET_MIXED_AUDIO returns (set per-test)
local mixed_audio_response = nil

local function reset_mocks()
    pcm_release_calls = {}
    sse_push_calls = {}
    sse_reset_calls = 0
    sse_set_target_calls = {}
    aop_start_calls = 0
    aop_stop_calls = 0
    aop_flush_calls = 0
    mix_params_calls = {}
    mixed_audio_response = nil
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
        CURRENT_TIME_US = function() return 0 end,
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
-- Cleanup
--------------------------------------------------------------------------------
teardown()

print("\n✅ test_audio_mix_tmb.lua passed")
