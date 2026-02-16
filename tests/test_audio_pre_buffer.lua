#!/usr/bin/env luajit
--- Test: audio_playback.pre_buffer pushes PCM ahead of transition.
-- set_audio_sources detects pre-buffered state and skips cold restart.
-- @file test_audio_pre_buffer.lua

require('test_env')

print("=== test_audio_pre_buffer.lua ===")

--------------------------------------------------------------------------------
-- Mock audio pipeline (tracks SSE.RESET calls to detect cold vs warm path)
--------------------------------------------------------------------------------

local sse_reset_count = 0
local sse_push_count = 0
local sse_set_target_count = 0
local aop_stop_count = 0
local aop_start_count = 0
local aop_playhead_us = 0
local pcm_fetch_log = {}

local mock_sse = { _name = "mock_sse" }
local mock_aop = { _name = "mock_aop" }

package.loaded["core.signals"] = { connect = function() end, emit = function() end }

package.loaded["core.qt_constants"] = {
    AOP = {
        OPEN = function() return mock_aop end,
        CLOSE = function() end,
        START = function() aop_start_count = aop_start_count + 1 end,
        STOP = function() aop_stop_count = aop_stop_count + 1 end,
        FLUSH = function() end,
        PLAYHEAD_US = function() return aop_playhead_us end,
        BUFFERED_FRAMES = function() return 0 end,
        WRITE_F32 = function(_, _, frames) return frames end,
        HAD_UNDERRUN = function() return false end,
        CLEAR_UNDERRUN = function() end,
        SAMPLE_RATE = function() return 48000 end,
        CHANNELS = function() return 2 end,
    },
    SSE = {
        CREATE = function() return mock_sse end,
        CLOSE = function() end,
        RESET = function() sse_reset_count = sse_reset_count + 1 end,
        SET_TARGET = function() sse_set_target_count = sse_set_target_count + 1 end,
        PUSH_PCM = function() sse_push_count = sse_push_count + 1 end,
        RENDER_ALLOC = function(_, frames) return "pcm", math.min(frames, 512) end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
        CURRENT_TIME_US = function() return 0 end,
    },
    EMP = {
        SET_DECODE_MODE = function() end,
    },
}

_G.qt_create_single_shot_timer = function() end

-- Mock Mixer
package.loaded["core.mixer"] = {
    mix_sources = function(sources, pb_start, pb_end, rate, ch, cache)
        return "mixed_pcm", math.floor((pb_end - pb_start) * rate / 1000000), pb_start
    end,
    decode_source = function(source, start_us, end_us, rate, ch, cache)
        return "decoded_pcm", math.floor((end_us - start_us) * rate / 1000000), start_us
    end,
}

-- Mock project_generation
package.loaded["core.project_generation"] = {
    current = function() return 1 end,
    check = function() end,
}

-- Mock cache
local mock_cache = {
    get_audio_pcm_for_path = function(path, start_us, end_us, out_rate)
        pcm_fetch_log[#pcm_fetch_log + 1] = { path = path, start_us = start_us, end_us = end_us }
        local rate = out_rate or 48000
        local frames = math.floor((end_us - start_us) * rate / 1000000)
        return "pcm_" .. path, frames, start_us
    end,
    ensure_audio_pooled = function() return { has_audio = true } end,
}

-- Load fresh audio_playback
package.loaded["core.media.audio_playback"] = nil
local audio_playback = require("core.media.audio_playback")

audio_playback.init_session(48000, 2)
audio_playback.set_max_time(10000000)

-- Source for "current" clip (clip A: 0-4s)
local source_a = {
    path = "/test/clip_a.mov",
    seek_us = 0,
    clip_start_us = 0,
    clip_end_us = 4000000,
    speed_ratio = 1.0,
    volume = 1.0,
}

-- Source for "next" clip (clip B: 4s-8s)
local source_b = {
    path = "/test/clip_b.mov",
    seek_us = 0,
    clip_start_us = 4000000,
    clip_end_us = 8000000,
    speed_ratio = 1.0,
    volume = 1.0,
}

--------------------------------------------------------------------------------
-- Test 1: pre_buffer pushes PCM to SSE for upcoming clip
--------------------------------------------------------------------------------

print("\n--- pre_buffer pushes PCM to SSE ---")
do
    audio_playback.set_audio_sources({ source_a }, mock_cache)

    sse_push_count = 0
    audio_playback.pre_buffer(source_b, mock_cache)

    assert(audio_playback._pre_buffered, "pre_buffer must set _pre_buffered state")
    assert(audio_playback._pre_buffered.clip_start_us == 4000000,
        "pre_buffered clip_start_us should be 4000000")

    print("  pre_buffer stores pre-buffered state passed")
end

--------------------------------------------------------------------------------
-- Test 2: set_audio_sources detects pre-buffered transition, skips RESET
--------------------------------------------------------------------------------

print("\n--- warm transition skips SSE.RESET ---")
do
    audio_playback.set_audio_sources({ source_a }, mock_cache)

    -- Pre-buffer clip B
    audio_playback.pre_buffer(source_b, mock_cache)

    -- Now transition to clip B (simulating what engine does at edit point)
    sse_reset_count = 0
    aop_stop_count = 0
    audio_playback.set_audio_sources({ source_b }, mock_cache)

    -- Warm path: SSE.RESET should NOT have been called
    assert(sse_reset_count == 0, string.format(
        "Warm transition should skip SSE.RESET, but RESET was called %d times",
        sse_reset_count))

    -- _pre_buffered should be consumed (nil after use)
    assert(audio_playback._pre_buffered == nil,
        "pre_buffered should be nil after warm transition consumed it")

    print("  warm transition skips SSE.RESET passed")
end

--------------------------------------------------------------------------------
-- Test 3: Cold path still works when not pre-buffered
--------------------------------------------------------------------------------

print("\n--- cold path works without pre-buffer ---")
do
    -- Clear any pre-buffer state
    audio_playback._pre_buffered = nil
    audio_playback.set_audio_sources({ source_a }, mock_cache)

    sse_reset_count = 0
    -- Transition without pre-buffer
    audio_playback.set_audio_sources({ source_b }, mock_cache)

    -- Cold path: SSE.RESET should have been called
    assert(sse_reset_count > 0, string.format(
        "Cold transition should call SSE.RESET, but got %d calls",
        sse_reset_count))

    print("  cold path calls SSE.RESET passed")
end

--------------------------------------------------------------------------------
-- Test 4: pre_buffer with mismatched source doesn't skip RESET
--------------------------------------------------------------------------------

print("\n--- mismatched pre-buffer falls through to cold path ---")
do
    audio_playback.set_audio_sources({ source_a }, mock_cache)

    -- Pre-buffer clip B
    audio_playback.pre_buffer(source_b, mock_cache)

    -- But transition to a DIFFERENT source (clip C, not clip B)
    local source_c = {
        path = "/test/clip_c.mov",
        seek_us = 0,
        clip_start_us = 8000000,
        clip_end_us = 12000000,
        speed_ratio = 1.0,
        volume = 1.0,
    }

    sse_reset_count = 0
    audio_playback.set_audio_sources({ source_c }, mock_cache)

    -- Mismatch: should fall through to cold path
    assert(sse_reset_count > 0, string.format(
        "Mismatched pre-buffer should fall through to cold path, RESET count=%d",
        sse_reset_count))

    -- Pre-buffer should be cleared
    assert(audio_playback._pre_buffered == nil,
        "pre_buffered should be cleared after mismatch")

    print("  mismatched pre-buffer falls through to cold path passed")
end

--------------------------------------------------------------------------------
-- Test 5: pre_buffer asserts on nil source
--------------------------------------------------------------------------------

print("\n--- pre_buffer asserts on nil source ---")
do
    local ok, err = pcall(audio_playback.pre_buffer, nil, mock_cache)
    assert(not ok, "Should assert on nil source")
    assert(err:find("source"), "Error should mention source, got: " .. err)
    print("  pre_buffer asserts on nil source passed")
end

--------------------------------------------------------------------------------
-- Test 6: pre_buffer asserts on nil cache
--------------------------------------------------------------------------------

print("\n--- pre_buffer asserts on nil cache ---")
do
    local ok, err = pcall(audio_playback.pre_buffer, source_b, nil)
    assert(not ok, "Should assert on nil cache")
    assert(err:find("cache"), "Error should mention cache, got: " .. err)
    print("  pre_buffer asserts on nil cache passed")
end

--------------------------------------------------------------------------------
-- Test 6b: pre_buffer asserts on missing source.path
--------------------------------------------------------------------------------

print("\n--- pre_buffer asserts on missing source.path ---")
do
    local bad_source = {
        clip_start_us = 0,
        clip_end_us = 4000000,
        speed_ratio = 1.0,
        volume = 1.0,
    }
    local ok, err = pcall(audio_playback.pre_buffer, bad_source, mock_cache)
    assert(not ok, "Should assert on missing source.path")
    assert(err:find("path"), "Error should mention path, got: " .. err)
    print("  pre_buffer asserts on missing source.path passed")
end

--------------------------------------------------------------------------------
-- Test 6c: pre_buffer does NOT set _pre_buffered when PCM decode fails
--------------------------------------------------------------------------------

print("\n--- pre_buffer skips _pre_buffered when no PCM pushed ---")
do
    -- Use a mixer mock that returns nil (decode failure)
    local orig_mix = package.loaded["core.mixer"].mix_sources
    package.loaded["core.mixer"].mix_sources = function()
        return nil, 0, 0  -- no PCM
    end

    audio_playback._pre_buffered = nil
    audio_playback.pre_buffer(source_b, mock_cache)

    assert(audio_playback._pre_buffered == nil,
        "_pre_buffered should NOT be set when no PCM was pushed")

    -- Restore original mixer
    package.loaded["core.mixer"].mix_sources = orig_mix
    print("  pre_buffer skips _pre_buffered when no PCM pushed passed")
end

--------------------------------------------------------------------------------
-- Test 7: shutdown_session clears _pre_buffered (C1)
--------------------------------------------------------------------------------

print("\n--- shutdown_session clears _pre_buffered ---")
do
    -- Session still initialized from prior tests — set up pre-buffer
    audio_playback.set_audio_sources({ source_a }, mock_cache)
    audio_playback.pre_buffer(source_b, mock_cache)

    assert(audio_playback._pre_buffered ~= nil,
        "pre_buffered should be set before shutdown")

    audio_playback.shutdown_session()

    assert(audio_playback._pre_buffered == nil,
        "pre_buffered must be nil after shutdown_session (stale buffer survives project switch)")

    print("  shutdown_session clears _pre_buffered passed")
end

--------------------------------------------------------------------------------
-- Test 8: Warm transition reanchors and restarts when playing (C2)
--------------------------------------------------------------------------------

print("\n--- warm transition reanchors when playing ---")
do
    -- Re-init
    audio_playback.init_session(48000, 2)
    audio_playback.set_max_time(10000000)

    -- Set initial sources and start playing
    audio_playback.set_audio_sources({ source_a }, mock_cache)
    audio_playback.playing = true  -- simulate playing state

    -- Pre-buffer clip B
    audio_playback.pre_buffer(source_b, mock_cache)

    -- Reset counters
    sse_reset_count = 0
    sse_set_target_count = 0
    aop_start_count = 0
    aop_stop_count = 0

    -- Transition to clip B while playing
    audio_playback.set_audio_sources({ source_b }, mock_cache)

    -- Warm path: SSE.RESET should NOT be called
    assert(sse_reset_count == 0, string.format(
        "Warm transition should skip SSE.RESET, got %d calls", sse_reset_count))

    -- But reanchor MUST happen (SSE.SET_TARGET called)
    assert(sse_set_target_count > 0, string.format(
        "Warm transition while playing must reanchor (SSE.SET_TARGET), got %d calls",
        sse_set_target_count))

    -- AOP.START must be called to maintain playback
    assert(aop_start_count > 0, string.format(
        "Warm transition while playing must call AOP.START, got %d calls",
        aop_start_count))

    -- Playback should still be active
    assert(audio_playback.playing == true,
        "Playing should still be true after warm transition")

    print("  warm transition reanchors when playing passed")
end

-- Cleanup
audio_playback.shutdown_session()

print("\n✅ test_audio_pre_buffer.lua passed")
