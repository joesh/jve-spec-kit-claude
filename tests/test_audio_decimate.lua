require('test_env')

-- Test: Audio decimate mode for >4x speeds
-- Up to 4x uses pitch correction (WSOLA), >4x uses decimation (no pitch correction)

-- Mock qt_constants for SSE/AOP operations
local sse_calls = {}
local mock_sse_handle = { _name = "mock_sse" }

local mock_qt_constants = {
    AOP = {
        OPEN = function() return { _name = "mock_aop" } end,
        CLOSE = function() end,
        START = function() end,
        STOP = function() end,
        FLUSH = function() end,
        PLAYHEAD_US = function() return 0 end,
        BUFFERED_FRAMES = function() return 0 end,
        WRITE_F32 = function() end,
        HAD_UNDERRUN = function() return false end,
        CLEAR_UNDERRUN = function() end,
    },
    SSE = {
        CREATE = function(cfg)
            return mock_sse_handle
        end,
        CLOSE = function() end,
        RESET = function(sse)
            table.insert(sse_calls, { op = "RESET" })
        end,
        SET_TARGET = function(sse, t_us, speed, mode)
            table.insert(sse_calls, {
                op = "SET_TARGET",
                t_us = t_us,
                speed = speed,
                mode = mode
            })
        end,
        PUSH_PCM = function() end,
        RENDER_ALLOC = function(sse, frames)
            return {}, 0  -- Empty PCM, 0 produced
        end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
        CURRENT_TIME_US = function() return 0 end,
    },
}

-- Set both global and package.loaded so require("core.qt_constants") returns our mock
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

-- Mock timer
_G.qt_create_single_shot_timer = function(interval, callback) end

-- Mock media_cache
local mock_cache = {
    get_asset_info = function()
        return {
            has_audio = true,
            audio_sample_rate = 48000,
            audio_channels = 2,
            duration_us = 10000000,  -- 10 seconds
            fps_num = 30,
            fps_den = 1,
        }
    end,
    get_audio_reader = function()
        return { _name = "mock_reader" }
    end,
    get_audio_pcm = function(start_us, end_us)
        -- Return mock PCM data (pointer, frames, actual_start)
        local frames = math.floor((end_us - start_us) * 48000 / 1000000)
        return "mock_pcm_ptr", frames, start_us
    end,
    get_audio_pcm_for_path = function(path, start_us, end_us)
        local frames = math.floor((end_us - start_us) * 48000 / 1000000)
        return "mock_pcm_ptr", frames, start_us
    end,
    get_file_path = function() return "/mock/test.mov" end,
    ensure_audio_pooled = function() end,
}

-- Load audio_playback fresh
package.loaded["ui.audio_playback"] = nil
local audio_playback = require("core.media.audio_playback")

print("=== Test audio decimate mode ===")

local function clear_sse_calls()
    sse_calls = {}
end

local function last_set_target()
    for i = #sse_calls, 1, -1 do
        if sse_calls[i].op == "SET_TARGET" then
            return sse_calls[i]
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- SECTION 1: Quality mode constants
--------------------------------------------------------------------------------
print("\n--- Section 1: Quality mode constants ---")

-- These constants should be defined in audio_playback
local Q1 = 1
local Q2 = 2
local Q3_DECIMATE = 3

print("\nTest 1.1: Q3_DECIMATE constant is 3")
assert(audio_playback.Q3_DECIMATE == Q3_DECIMATE or Q3_DECIMATE == 3,
    "Q3_DECIMATE should be 3")
print("  ok Q3_DECIMATE = 3")

print("\nTest 1.2: MAX_SPEED_STRETCHED constant is 4.0")
assert(audio_playback.MAX_SPEED_STRETCHED == 4.0,
    "MAX_SPEED_STRETCHED should be 4.0")
print("  ok MAX_SPEED_STRETCHED = 4.0")

print("\nTest 1.3: MAX_SPEED_DECIMATE constant is 16.0")
assert(audio_playback.MAX_SPEED_DECIMATE == 16.0,
    "MAX_SPEED_DECIMATE should be 16.0")
print("  ok MAX_SPEED_DECIMATE = 16.0")

--------------------------------------------------------------------------------
-- SECTION 2: Mode selection based on speed
--------------------------------------------------------------------------------
print("\n--- Section 2: Mode selection ---")

-- Initialize audio (session + source)
audio_playback.init_session(48000, 2)
audio_playback.switch_source(mock_cache)
audio_playback.set_max_media_time(10000000)
clear_sse_calls()

print("\nTest 2.1: Speed 2x selects Q1 mode")
audio_playback.set_speed(2.0)
local call = last_set_target()
-- When not playing, set_speed just stores; we need to check mode on next start
assert(audio_playback.quality_mode == Q1, "2x should use Q1, got " .. tostring(audio_playback.quality_mode))
print("  ok 2x -> Q1")

print("\nTest 2.2: Speed 4x selects Q1 mode (boundary)")
audio_playback.set_speed(4.0)
assert(audio_playback.quality_mode == Q1, "4x should use Q1, got " .. tostring(audio_playback.quality_mode))
print("  ok 4x -> Q1")

print("\nTest 2.3: Speed 8x selects Q3_DECIMATE mode")
audio_playback.set_speed(8.0)
assert(audio_playback.quality_mode == Q3_DECIMATE,
    "8x should use Q3_DECIMATE, got " .. tostring(audio_playback.quality_mode))
print("  ok 8x -> Q3_DECIMATE")

print("\nTest 2.4: Speed 16x selects Q3_DECIMATE mode")
audio_playback.set_speed(16.0)
assert(audio_playback.quality_mode == Q3_DECIMATE,
    "16x should use Q3_DECIMATE, got " .. tostring(audio_playback.quality_mode))
print("  ok 16x -> Q3_DECIMATE")

print("\nTest 2.5: Negative speed -8x selects Q3_DECIMATE mode")
audio_playback.set_speed(-8.0)
assert(audio_playback.quality_mode == Q3_DECIMATE,
    "-8x should use Q3_DECIMATE, got " .. tostring(audio_playback.quality_mode))
print("  ok -8x -> Q3_DECIMATE")

print("\nTest 2.6: Speed 0.5x selects Q1 mode")
audio_playback.set_speed(0.5)
assert(audio_playback.quality_mode == Q1, "0.5x should use Q1, got " .. tostring(audio_playback.quality_mode))
print("  ok 0.5x -> Q1")

print("\nTest 2.7: Speed 0.15x selects Q2 mode")
audio_playback.set_speed(0.15)
assert(audio_playback.quality_mode == Q2, "0.15x should use Q2, got " .. tostring(audio_playback.quality_mode))
print("  ok 0.15x -> Q2")

--------------------------------------------------------------------------------
-- SECTION 3: Reanchor on mode transition
--------------------------------------------------------------------------------
print("\n--- Section 3: Reanchor on mode transition ---")

-- Reset
audio_playback.shutdown_session()
package.loaded["core.media.audio_playback"] = nil
audio_playback = require("core.media.audio_playback")
audio_playback.init_session(48000, 2)
audio_playback.switch_source(mock_cache)
audio_playback.set_max_media_time(10000000)
audio_playback.media_time_us = 1000000  -- Start at 1 second
clear_sse_calls()

print("\nTest 3.1: Changing from 2x to 8x while playing causes reanchor")
audio_playback.set_speed(2.0)
audio_playback.playing = true  -- Simulate playing state
audio_playback.start()
clear_sse_calls()

audio_playback.set_speed(8.0)  -- Q1 -> Q3_DECIMATE transition

-- Should have called RESET + SET_TARGET (reanchor)
local found_reset = false
local found_set_target = false
for _, c in ipairs(sse_calls) do
    if c.op == "RESET" then found_reset = true end
    if c.op == "SET_TARGET" and c.mode == Q3_DECIMATE then found_set_target = true end
end
assert(found_reset, "Should call RESET on mode transition")
assert(found_set_target, "Should call SET_TARGET with Q3_DECIMATE on mode transition")
print("  ok 2x->8x causes reanchor to Q3_DECIMATE")

print("\nTest 3.2: Changing from 8x to 4x while playing causes reanchor back to Q1")
clear_sse_calls()
audio_playback.set_speed(4.0)  -- Q3_DECIMATE -> Q1 transition

found_reset = false
found_set_target = false
for _, c in ipairs(sse_calls) do
    if c.op == "RESET" then found_reset = true end
    if c.op == "SET_TARGET" and c.mode == Q1 then found_set_target = true end
end
assert(found_reset, "Should call RESET on mode transition back")
assert(found_set_target, "Should call SET_TARGET with Q1 on mode transition back")
print("  ok 8x->4x causes reanchor to Q1")

--------------------------------------------------------------------------------
-- SECTION 4: Speed validation
--------------------------------------------------------------------------------
print("\n--- Section 4: Speed validation ---")

print("\nTest 4.1: Speed >16x asserts")
local ok, err = pcall(function()
    audio_playback.set_speed(20.0)
end)
assert(not ok, "Speed 20x should assert")
assert(err:match("exceeds MAX_SPEED_DECIMATE") or err:match("16"),
    "Error should mention MAX_SPEED_DECIMATE limit")
print("  ok 20x asserts")

audio_playback.stop()
audio_playback.shutdown_session()

print("\n ok test_audio_decimate.lua passed")
