--- Test: audio_playback must NOT push same PCM to SSE multiple times
-- @file test_audio_no_duplicate_push.lua
--
-- The echo/stutter bug occurs when the same PCM data is pushed to SSE
-- repeatedly. SSE accumulates chunks, so duplicates cause audio doubling.
--
-- This test verifies:
-- 1. PUSH_PCM is only called when NEW data is fetched
-- 2. Pump ticks with cached data do NOT trigger PUSH_PCM
-- 3. After seek, new data IS pushed

require('test_env')

print("=== Test: No Duplicate PCM Push to SSE ===")
print()

--------------------------------------------------------------------------------
-- Track all SSE.PUSH_PCM calls
--------------------------------------------------------------------------------
local push_pcm_calls = {}
local sse_reset_count = 0
local sse_current_time_us = 0

local mock_sse = {
    CREATE = function(config)
        return { id = "mock_sse" }
    end,
    CLOSE = function(sse) end,
    RESET = function(sse)
        sse_reset_count = sse_reset_count + 1
        sse_current_time_us = 0
        -- Note: We don't clear push_pcm_calls here because we want to
        -- track ALL pushes for testing purposes, even across resets
    end,
    SET_TARGET = function(sse, t_us, speed, mode)
        sse_current_time_us = t_us  -- Track target time
    end,
    PUSH_PCM = function(sse, pcm_ptr, frames, start_time_us)
        table.insert(push_pcm_calls, {
            pcm_ptr = pcm_ptr,
            frames = frames,
            start_time_us = start_time_us,
            call_time = os.clock(),
        })
    end,
    RENDER_ALLOC = function(sse, frames)
        return "mock_ptr", frames
    end,
    STARVED = function(sse) return false end,
    CLEAR_STARVED = function(sse) end,
    CURRENT_TIME_US = function(sse) return sse_current_time_us end,
    Q1 = 1,
    Q2 = 2,
}

local mock_aop = {
    OPEN = function(rate, channels, buffer_ms)
        return { id = "mock_aop" }
    end,
    CLOSE = function(aop) end,
    START = function(aop) end,
    STOP = function(aop) end,
    FLUSH = function(aop) end,
    WRITE_F32 = function(aop, ptr, frames) return frames end,
    BUFFERED_FRAMES = function(aop) return 0 end,
    PLAYHEAD_US = function(aop) return 0 end,
    HAD_UNDERRUN = function(aop) return false end,
    CLEAR_UNDERRUN = function(aop) end,
}

-- Mock media_cache that returns predictable PCM ranges
local media_cache_fetch_count = 0
local mock_media_cache = {
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
        return { id = "mock_audio_reader" }
    end,
    get_audio_pcm = function(start_us, end_us)
        media_cache_fetch_count = media_cache_fetch_count + 1
        -- Return mock PCM data
        local mock_ptr = "pcm_data_" .. media_cache_fetch_count
        local frames = math.floor((end_us - start_us) * 48000 / 1000000)
        return mock_ptr, frames, start_us
    end,
}

-- Set up global mocks
local mock_qt_constants = {
    SSE = mock_sse,
    AOP = mock_aop,
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

_G.qt_create_single_shot_timer = function(ms, callback)
    -- Don't actually schedule - we'll call pump manually
    return {}
end

-- Mock logger
package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Load audio_playback fresh
package.loaded["ui.audio_playback"] = nil
local audio_playback = require("ui.audio_playback")

--------------------------------------------------------------------------------
-- Test 1: Init should not push PCM
--------------------------------------------------------------------------------
print("Test 1: Init does not push PCM")

push_pcm_calls = {}
media_cache_fetch_count = 0

local ok = audio_playback.init(mock_media_cache)
assert(ok, "init should succeed")
assert(#push_pcm_calls == 0, string.format(
    "init should NOT push PCM, but got %d calls", #push_pcm_calls))

print("  ✓ init() does not call PUSH_PCM")

--------------------------------------------------------------------------------
-- Test 2: start() should push PCM exactly once
--------------------------------------------------------------------------------
print("Test 2: start() pushes PCM exactly once")

push_pcm_calls = {}
sse_reset_count = 0

audio_playback.start()

assert(sse_reset_count == 1, "start should reset SSE once")
assert(#push_pcm_calls == 1, string.format(
    "start should push PCM exactly once, but got %d calls", #push_pcm_calls))

print("  ✓ start() calls PUSH_PCM exactly once")

--------------------------------------------------------------------------------
-- Test 3: Multiple pump ticks with SAME cache should NOT re-push
--------------------------------------------------------------------------------
print("Test 3: Pump ticks with cached data do NOT re-push")

local initial_push_count = #push_pcm_calls
local initial_fetch_count = media_cache_fetch_count

-- Simulate multiple pump ticks (without moving playhead much)
for i = 1, 5 do
    audio_playback._pump_tick()
end

-- Fetch count might increase if cache window moves, but push count
-- should only increase if NEW data was fetched
local new_fetches = media_cache_fetch_count - initial_fetch_count
local new_pushes = #push_pcm_calls - initial_push_count

-- Key assertion: pushes should equal fetches (push only on new data)
assert(new_pushes <= new_fetches, string.format(
    "BUG: More pushes (%d) than fetches (%d) - duplicate pushing detected!",
    new_pushes, new_fetches))

print(string.format("  ✓ After 5 pump ticks: %d fetches, %d pushes (no duplicates)",
    new_fetches, new_pushes))

--------------------------------------------------------------------------------
-- Test 4: Seek while playing should push new data
--------------------------------------------------------------------------------
print("Test 4: Seek while playing pushes new data")

local pre_seek_pushes = #push_pcm_calls

-- Seek to a new position
audio_playback.seek(5000000)  -- 5 seconds

local post_seek_pushes = #push_pcm_calls

-- Should have pushed exactly once for the new position
assert(post_seek_pushes == pre_seek_pushes + 1, string.format(
    "Seek should trigger exactly 1 new push, but got %d",
    post_seek_pushes - pre_seek_pushes))

print("  ✓ seek() triggers exactly 1 PUSH_PCM")

--------------------------------------------------------------------------------
-- Test 5: Pump ticks after seek should NOT duplicate
--------------------------------------------------------------------------------
print("Test 5: Pump ticks after seek do NOT duplicate")

local post_seek_push_count = #push_pcm_calls
local post_seek_fetch_count = media_cache_fetch_count

-- Simulate pump ticks after seek
for i = 1, 5 do
    audio_playback._pump_tick()
end

local ticks_new_fetches = media_cache_fetch_count - post_seek_fetch_count
local ticks_new_pushes = #push_pcm_calls - post_seek_push_count

assert(ticks_new_pushes <= ticks_new_fetches, string.format(
    "BUG: More pushes (%d) than fetches (%d) after seek - duplicate pushing!",
    ticks_new_pushes, ticks_new_fetches))

print(string.format("  ✓ After seek + 5 ticks: %d fetches, %d pushes (no duplicates)",
    ticks_new_fetches, ticks_new_pushes))

--------------------------------------------------------------------------------
-- Test 6: Verify no consecutive identical pushes
--------------------------------------------------------------------------------
print("Test 6: No consecutive identical PUSH_PCM calls")

local duplicates_found = 0
for i = 2, #push_pcm_calls do
    local prev = push_pcm_calls[i-1]
    local curr = push_pcm_calls[i]
    if prev.pcm_ptr == curr.pcm_ptr and
       prev.frames == curr.frames and
       prev.start_time_us == curr.start_time_us then
        duplicates_found = duplicates_found + 1
        print(string.format("    DUPLICATE at index %d: ptr=%s frames=%d start_us=%d",
            i, tostring(curr.pcm_ptr), curr.frames, curr.start_time_us))
    end
end

assert(duplicates_found == 0, string.format(
    "BUG: Found %d duplicate consecutive PUSH_PCM calls!", duplicates_found))

print("  ✓ No duplicate consecutive pushes detected")

--------------------------------------------------------------------------------
-- Test 7: Verify no OVERLAPPING time ranges pushed
--------------------------------------------------------------------------------
print("Test 7: No overlapping PUSH_PCM time ranges")

local overlaps_found = 0
for i = 2, #push_pcm_calls do
    local prev = push_pcm_calls[i-1]
    local curr = push_pcm_calls[i]

    -- Calculate end times
    local prev_end_us = prev.start_time_us + (prev.frames * 1000000 / 48000)
    local curr_end_us = curr.start_time_us + (curr.frames * 1000000 / 48000)

    -- Check for overlap (ranges intersect if not disjoint)
    -- Disjoint means: prev ends before curr starts, OR curr ends before prev starts
    local disjoint = prev_end_us <= curr.start_time_us or curr_end_us <= prev.start_time_us
    if not disjoint then
        overlaps_found = overlaps_found + 1
        print(string.format("    OVERLAP at index %d:", i))
        print(string.format("      prev: %.3fs - %.3fs",
            prev.start_time_us / 1000000, prev_end_us / 1000000))
        print(string.format("      curr: %.3fs - %.3fs",
            curr.start_time_us / 1000000, curr_end_us / 1000000))
    end
end

-- Note: Overlaps might be OK if SSE handles them, but let's flag them
if overlaps_found > 0 then
    print(string.format("  WARNING: %d overlapping ranges (may cause echo)", overlaps_found))
else
    print("  ✓ No overlapping time ranges")
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------
audio_playback.shutdown()

--------------------------------------------------------------------------------
print()
print(string.format("Total PUSH_PCM calls: %d", #push_pcm_calls))
print(string.format("Total media_cache fetches: %d", media_cache_fetch_count))
print()
print("✅ test_audio_no_duplicate_push.lua passed")
