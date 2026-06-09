require('test_env')

-- Test: audio_playback boundary asserts at the AOP edge.
--
-- Speed-band → quality-mode picking is covered by
-- test_audio_quality_mode.lua as a pure function; the prior sections of
-- this file that re-checked those bands through audio_playback.set_speed
-- (and the reanchor-on-mode-transition mock-spy section) were redundant
-- and have been removed. What remains is the two assertions that
-- legitimately require the AOP system boundary:
--   §1 (was §4): set_speed > MAX_SPEED_DECIMATE must assert.
--   §2 (was §5, NSF-F4): init_session must assert when the audio device
--                        opens at a different sample rate than requested.
--
-- AOP/SSE/EMP are stubbed because they ARE the system boundary
-- (real audio device, real C++ SSE) — not assumption-encoding mocks.

local mock_qt_constants = {
    AOP = {
        OPEN = function() return { _name = "mock_aop" } end,
        CLOSE = function() end,
        START = function() end,
        STOP = function() end,
        FLUSH = function() end,
        PLAYHEAD_US = function() return 0 end,
        BUFFERED_FRAMES = function() return 0 end,
        _TEST_WRITE_F32 = function() end,
        HAD_UNDERRUN = function() return false end,
        CLEAR_UNDERRUN = function() end,
    },
    SSE = {
        CREATE = function() return { _name = "mock_sse" } end,
        CLOSE = function() end,
        RESET = function() end,
        SET_TARGET = function() end,
        PUSH_PCM = function() end,
        _TEST_RENDER_ALLOC = function() return {}, 0 end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
        CURRENT_TIME_US = function() return 0 end,
    },
    EMP = {
        TMB_GET_TRACK_AUDIO = function() return nil end,
        TMB_SET_AUDIO_MIX_PARAMS = function() end,
        TMB_GET_MIXED_AUDIO = function() return nil end,
        PCM_INFO = function() return { frames = 0, start_time_us = 0 } end,
        PCM_DATA_PTR = function() return nil end,
        PCM_RELEASE = function() end,
    },
}

_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants
_G.qt_create_single_shot_timer = function() end

package.loaded["core.media.audio_playback"] = nil
local audio_playback = require("core.media.audio_playback")

print("=== Test audio_playback boundary asserts ===")

-- ── §1: Speed > MAX_SPEED_DECIMATE must assert ───────────────────────
print("\n--- §1: Speed > MAX_SPEED_DECIMATE asserts ---")
audio_playback.init_session(48000, 2)
audio_playback.apply_mix("mock_tmb", {
    { track_index = 1, volume = 1.0, muted = false, soloed = false },
}, 0)
audio_playback.set_max_time(10000000)

local ok, err = pcall(function() audio_playback.set_speed(20.0) end)
assert(not ok, "Speed 20x should assert")
assert(err:match("exceeds MAX_SPEED_DECIMATE") or err:match("16"),
    "Error should mention MAX_SPEED_DECIMATE limit; got: " .. tostring(err))
print("  ok 20x asserts")

audio_playback.stop()
audio_playback.shutdown_session()

-- ── §2 (NSF-F4): Sample-rate mismatch must assert ────────────────────
print("\n--- §2 (NSF-F4): Sample-rate mismatch asserts ---")

package.loaded["core.media.audio_playback"] = nil
mock_qt_constants.AOP.OPEN         = function() return { _name = "mismatch_aop" } end
mock_qt_constants.AOP.SAMPLE_RATE  = function() return 44100 end  -- device != requested
mock_qt_constants.AOP.CHANNELS     = function() return 2 end

audio_playback = require("core.media.audio_playback")

local ok5, err5 = pcall(function() audio_playback.init_session(48000, 2) end)
assert(not ok5, "Should assert on sample rate mismatch")
assert(tostring(err5):find("sample rate mismatch"),
    "Error should mention sample rate mismatch; got: " .. tostring(err5))
print("  ok 44100 ≠ 48000 asserts")

-- And: matching rate must succeed (proves the assert is rate-driven, not a hard fail).
mock_qt_constants.AOP.SAMPLE_RATE = function() return 48000 end
package.loaded["core.media.audio_playback"] = nil
audio_playback = require("core.media.audio_playback")

local ok6, err6 = pcall(function() audio_playback.init_session(48000, 2) end)
assert(ok6, "Should succeed when rates match; got: " .. tostring(err6))
audio_playback.shutdown_session()
print("  ok 48000 == 48000 succeeds")

print("\n ok test_audio_decimate.lua passed")
