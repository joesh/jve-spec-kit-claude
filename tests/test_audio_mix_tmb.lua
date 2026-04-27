#!/usr/bin/env luajit
--- Test TMB-based audio mix path (apply_mix).
--
-- Verifies:
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

-- Phase 3: Check if pump functions are stubs (C++ owns pump now)
-- Tests that verify pump behavior are skipped when stubs are active
local audio_playback = require("core.media.audio_playback")

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
        _TEST_RENDER_ALLOC = function(sse, frames) return ffi.new("float[?]", frames * 2), 0 end,
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
        _TEST_WRITE_F32 = function() end,
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
    for_area = function() return { event = function() end, detail = function() end, warn = function() end, error = function() end } end,
}

-- Mock project_generation
package.loaded["core.project_generation"] = {
    current = function() return 1 end,
    check = function() end,
}

-- audio_playback already required at top

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
-- F5.4: send_mix_params_to_tmb resolves solo/mute correctly
--   (F5.1-F5.3c and G1-G4 tested the Lua-side pump that was moved to
--    C++ AudioPump and have been deleted along with the stubs.)
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

    -- Verify TMB received the new volume (observable via mock capture)
    local last_call = mix_params_calls[#mix_params_calls]
    assert(last_call.params[1].volume == 0.5,
        "TMB should receive updated volume 0.5")

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
    -- Verify TMB received resolved volume=0 (muted track → volume 0)
    local last_call = mix_params_calls[#mix_params_calls]
    assert(last_call.params[1].volume == 0,
        string.format("Muted track should resolve to volume 0, got %s",
            tostring(last_call.params[1].volume)))

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

print("\n--- F6.6: track change while playing → hot update (TMB handles transition) ---")
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

    -- Track change while playing → TMB handles it, no stop/restart
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 5000000)

    assert(aop_stop_calls == 0, "Track change during playback must NOT stop AOP (TMB handles it)")
    assert(audio_playback.playing == true, "Should remain playing")

    print("  track change while playing → hot update passed")
end

print("\n--- F6.6b: all tracks removed during playback → AOP stops ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000

    -- Simulate playing state
    audio_playback.playing = true
    aop_stop_calls = 0

    -- Remove all tracks during playback
    audio_playback.apply_mix(mock_tmb, {}, 5000000)

    assert(audio_playback.has_audio == false,
        "has_audio must be false after removing all tracks")
    assert(audio_playback.playing == false,
        "Must stop playing when all audio tracks removed")
    assert(aop_stop_calls > 0,
        "Must stop AOP when all audio tracks removed during playback")

    print("  all tracks removed during playback → AOP stops passed")
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

    -- SSE invalidation verification (skipped in Phase 3 - C++ owns pump)

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
-- G1-G4: Pump/extension tests (moved to C++ in Phase 3)
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- F11: Clip boundary cache nuke regression — identical resolved params should
-- NOT call TMB_SET_AUDIO_MIX_PARAMS a second time (prevents mix cache nuke).
-- Bug: at audio clip boundaries, apply_mix fires even though the track set
-- and volumes are identical. send_mix_params_to_tmb called SetAudioMixParams
-- unconditionally, which clears the C++ mixed audio cache. Next GetMixedAudio
-- falls through to sync decode on main thread, blocking pump → AOP underrun.
--------------------------------------------------------------------------------

print("\n--- F11.1: identical resolved params → no redundant TMB_SET_AUDIO_MIX_PARAMS ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- First apply_mix: track 1 at full volume
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    local calls_after_first = #mix_params_calls
    assert(calls_after_first >= 1,
        "First apply_mix must call TMB_SET_AUDIO_MIX_PARAMS")

    -- Second apply_mix: IDENTICAL params (simulates clip boundary, same track)
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 1000000)

    assert(#mix_params_calls == calls_after_first, string.format(
        "Identical resolved params must NOT re-call TMB_SET_AUDIO_MIX_PARAMS "
        .. "(expected %d calls, got %d)", calls_after_first, #mix_params_calls))

    print("  identical params → no redundant TMB call passed")
end

print("\n--- F11.2: different volume → DOES call TMB_SET_AUDIO_MIX_PARAMS ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    -- First apply_mix
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    local calls_after_first = #mix_params_calls

    -- Second with different volume → resolved params differ → must call
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 0.5, muted = false, soloed = false },
    }, 1000000)

    assert(#mix_params_calls > calls_after_first,
        "Different volume must trigger TMB_SET_AUDIO_MIX_PARAMS")

    print("  different volume → TMB call passed")
end

print("\n--- F11.3: mute toggle → DOES call TMB_SET_AUDIO_MIX_PARAMS ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"

    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    local calls_after_first = #mix_params_calls

    -- Mute → resolved volume changes from 1.0 to 0
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = true, soloed = false },
    }, 1000000)

    assert(#mix_params_calls > calls_after_first,
        "Mute toggle must trigger TMB_SET_AUDIO_MIX_PARAMS (volume 1.0 → 0)")

    print("  mute toggle → TMB call passed")
end

print("\n--- F11.4: identical params during playback → no cache nuke ---")
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
    audio_playback.playing = true

    local calls_after_first = #mix_params_calls

    -- Clip boundary during playback: same track, same settings
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 5000000)

    assert(#mix_params_calls == calls_after_first, string.format(
        "Identical params during playback must NOT nuke C++ mix cache "
        .. "(expected %d calls, got %d)", calls_after_first, #mix_params_calls))
    assert(audio_playback.playing == true, "Must remain playing")

    print("  identical params during playback → no cache nuke passed")
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------
teardown()

print("\n✅ test_audio_mix_tmb.lua passed")
