#!/usr/bin/env luajit
--- Test TMB-based audio mix path (decode_mix_and_send_to_sse + apply_mix).
--
-- Replaces coverage from deleted test_mixer.lua/test_mixer_extended.lua.
-- Verifies:
-- - Single-track decode + push to SSE
-- - Multi-track mixing with volume scaling
-- - Solo/mute logic
-- - PCM_RELEASE lifecycle
-- - Dedup (same pb_start skipped)
-- - apply_mix hot-swap vs cold-swap
--
-- Uses real FFI for float arrays to verify actual mixing math.
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

-- Per-track PCM responses: {[track_index] = {buf=ffi_float_ptr, info={frames, start_time_us}}}
local track_pcm_map = {}

local function reset_mocks()
    pcm_release_calls = {}
    sse_push_calls = {}
    sse_reset_calls = 0
    sse_set_target_calls = {}
    aop_start_calls = 0
    aop_stop_calls = 0
    aop_flush_calls = 0
    track_pcm_map = {}
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
        TMB_GET_TRACK_AUDIO = function(tmb, track_index, t0, t1, sr, ch)
            local entry = track_pcm_map[track_index]
            if not entry then return nil end
            return entry
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
-- F5: decode_mix_and_send_to_sse tests
--------------------------------------------------------------------------------

print("\n--- F5.1: single track, volume 1.0 ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    -- Set up mix with 1 track
    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000  -- 5s (center of 10s window)
    audio_playback.max_media_time_us = 10000000

    -- Mock TMB returns 100 frames of value 0.5
    track_pcm_map[1] = make_pcm(100, CHANNELS, 0, 0.5)

    -- Call decode
    audio_playback.decode_mix_and_send_to_sse()

    -- Should have pushed to SSE
    assert(#sse_push_calls == 1, string.format(
        "Expected 1 SSE push, got %d", #sse_push_calls))
    assert(sse_push_calls[1].frames == 100, string.format(
        "Expected 100 frames, got %d", sse_push_calls[1].frames))

    -- Verify sample values (volume 1.0, should be unchanged 0.5)
    for i = 1, 100 * CHANNELS do
        assert(approx(sse_push_calls[1].data[i], 0.5), string.format(
            "Sample[%d] should be 0.5, got %f", i, sse_push_calls[1].data[i]))
    end

    -- PCM should be released
    assert(#pcm_release_calls == 1, "PCM should be released after mixing")

    print("  single track volume 1.0 passed")
end

print("\n--- F5.2: single track, volume 0.5 ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 0.5, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    track_pcm_map[1] = make_pcm(100, CHANNELS, 0, 1.0)

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 1, "Expected 1 SSE push")
    -- Volume 0.5 applied to 1.0 → 0.5
    for i = 1, 100 * CHANNELS do
        assert(approx(sse_push_calls[1].data[i], 0.5), string.format(
            "Sample[%d] should be 0.5 (1.0 * 0.5), got %f", i, sse_push_calls[1].data[i]))
    end

    print("  single track volume 0.5 passed")
end

print("\n--- F5.3: multi-track mixing ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = false },
        { track_index = 2, volume = 0.5, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    -- Track 1: all 0.3, Track 2: all 0.4
    track_pcm_map[1] = make_pcm(100, CHANNELS, 0, 0.3)
    track_pcm_map[2] = make_pcm(100, CHANNELS, 0, 0.4)

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 1, "Expected 1 SSE push (mixed)")
    -- Mix: track1 * 1.0 + track2 * 0.5 = 0.3 + 0.2 = 0.5
    for i = 1, 100 * CHANNELS do
        assert(approx(sse_push_calls[1].data[i], 0.5), string.format(
            "Sample[%d] should be 0.5 (0.3*1.0 + 0.4*0.5), got %f",
            i, sse_push_calls[1].data[i]))
    end

    -- Both PCMs released
    assert(#pcm_release_calls == 2, string.format(
        "Expected 2 PCM releases, got %d", #pcm_release_calls))

    print("  multi-track mixing passed")
end

print("\n--- F5.4: muted track excluded ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = true, soloed = false },
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    track_pcm_map[1] = make_pcm(100, CHANNELS, 0, 0.7)  -- muted: should be ignored
    track_pcm_map[2] = make_pcm(100, CHANNELS, 0, 0.3)

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 1, "Expected 1 SSE push")
    -- Only track 2 (unmuted): 0.3 * 1.0 = 0.3
    for i = 1, 100 * CHANNELS do
        assert(approx(sse_push_calls[1].data[i], 0.3), string.format(
            "Sample[%d] should be 0.3 (muted track excluded), got %f",
            i, sse_push_calls[1].data[i]))
    end

    -- Only track 2's PCM released (track 1 skipped entirely due to vol=0)
    assert(#pcm_release_calls == 1, string.format(
        "Expected 1 PCM release (muted track skipped), got %d", #pcm_release_calls))

    print("  muted track excluded passed")
end

print("\n--- F5.5: solo logic ---")
do
    reset_mocks()
    teardown()
    init_test_session()

    local mock_tmb = "test_tmb"
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 1.0, muted = false, soloed = true },
        { track_index = 2, volume = 1.0, muted = false, soloed = false },
    }, 0)
    audio_playback.set_max_time(10000000)
    audio_playback.media_time_us = 5000000
    audio_playback.max_media_time_us = 10000000

    track_pcm_map[1] = make_pcm(100, CHANNELS, 0, 0.8)
    track_pcm_map[2] = make_pcm(100, CHANNELS, 0, 0.5)  -- not soloed: excluded

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 1, "Expected 1 SSE push")
    -- Solo: only track 1 plays
    for i = 1, 100 * CHANNELS do
        assert(approx(sse_push_calls[1].data[i], 0.8), string.format(
            "Sample[%d] should be 0.8 (only soloed track), got %f",
            i, sse_push_calls[1].data[i]))
    end

    print("  solo logic passed")
end

print("\n--- F5.6: TMB returns nil PCM → track skipped gracefully ---")
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
    audio_playback.max_media_time_us = 10000000

    -- Track 1: nil (gap), Track 2: has data
    track_pcm_map[1] = nil
    track_pcm_map[2] = make_pcm(100, CHANNELS, 0, 0.6)

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 1, "Expected 1 SSE push (track 2 only)")
    for i = 1, 100 * CHANNELS do
        assert(approx(sse_push_calls[1].data[i], 0.6), string.format(
            "Sample[%d] should be 0.6 (track 1 gap skipped), got %f",
            i, sse_push_calls[1].data[i]))
    end

    print("  nil PCM track skipped passed")
end

print("\n--- F5.7: all tracks nil → no SSE push ---")
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

    track_pcm_map[1] = nil  -- gap

    audio_playback.decode_mix_and_send_to_sse()

    assert(#sse_push_calls == 0, string.format(
        "Expected 0 SSE pushes (all gaps), got %d", #sse_push_calls))

    print("  all tracks nil → no push passed")
end

print("\n--- F5.8: dedup skips second call with same pb_start ---")
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

    track_pcm_map[1] = make_pcm(100, CHANNELS, 0, 0.5)

    -- First call: should push
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, "First call should push")

    -- Second call: same position → should be deduped
    audio_playback.decode_mix_and_send_to_sse()
    assert(#sse_push_calls == 1, string.format(
        "Second call should be deduped, got %d pushes", #sse_push_calls))

    print("  dedup passed")
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
    sse_reset_calls = 0  -- clear reset from initial apply

    -- Hot swap: same track, different volume
    audio_playback.apply_mix(mock_tmb, {
        { track_index = 1, volume = 0.5, muted = false, soloed = false },
    }, 1000000)

    assert(sse_reset_calls == 0, string.format(
        "Hot swap should NOT reset SSE, got %d resets", sse_reset_calls))

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

    -- Track 1 data for restart decode
    track_pcm_map[1] = make_pcm(100, CHANNELS, 0, 0.5)

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

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------
teardown()

print("\n✅ test_audio_mix_tmb.lua passed")
