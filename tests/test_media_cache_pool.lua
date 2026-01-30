--- Test media_cache multi-reader LRU pool
-- @file test_media_cache_pool.lua
--
-- Tests the LRU reader pool that replaces single-asset load/unload:
-- - activate() opens reader on first call, no-ops on repeat
-- - Pool tracks multiple open readers (max_readers=4)
-- - LRU eviction closes oldest reader when pool full
-- - is_loaded() reflects active reader state
-- - get_video_frame() works with active reader
-- - cleanup() releases all pooled readers

require('test_env')

-- Track resource lifecycle for verification
local open_assets = {}
local open_readers = {}
local closed_assets = {}
local closed_readers = {}
local asset_counter = 0
local reader_counter = 0
local stopped_prefetch = {}
local decode_calls = {}
local max_cache_calls = {}

local function make_mock_asset(path)
    asset_counter = asset_counter + 1
    local id = "asset_" .. asset_counter
    open_assets[id] = path
    return id
end

local function make_mock_reader(asset_id)
    reader_counter = reader_counter + 1
    local id = "reader_" .. reader_counter
    open_readers[id] = asset_id
    return id
end

local mock_qt_constants = {
    EMP = {
        ASSET_OPEN = function(path)
            return make_mock_asset(path)
        end,
        ASSET_INFO = function(asset)
            assert(open_assets[asset], "ASSET_INFO: asset not open: " .. tostring(asset))
            return {
                has_video = true,
                has_audio = true,
                width = 1920,
                height = 1080,
                fps_num = 24,
                fps_den = 1,
                duration_us = 10000000,
                audio_sample_rate = 48000,
                audio_channels = 2,
            }
        end,
        ASSET_CLOSE = function(asset)
            assert(open_assets[asset], "ASSET_CLOSE: asset not open: " .. tostring(asset))
            table.insert(closed_assets, asset)
            open_assets[asset] = nil
        end,
        READER_CREATE = function(asset)
            assert(open_assets[asset], "READER_CREATE: asset not open: " .. tostring(asset))
            return make_mock_reader(asset)
        end,
        READER_CLOSE = function(reader)
            assert(open_readers[reader], "READER_CLOSE: reader not open: " .. tostring(reader))
            table.insert(closed_readers, reader)
            open_readers[reader] = nil
        end,
        READER_DECODE_FRAME = function(reader, frame_idx, fps_num, fps_den)
            assert(open_readers[reader], "READER_DECODE_FRAME: reader not open: " .. tostring(reader))
            table.insert(decode_calls, {reader = reader, frame_idx = frame_idx})
            return "frame_" .. frame_idx
        end,
        READER_STOP_PREFETCH = function(reader)
            table.insert(stopped_prefetch, reader)
        end,
        READER_SET_MAX_CACHE = function(reader, max_frames)
            table.insert(max_cache_calls, {reader = reader, max_frames = max_frames})
        end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        SET_DECODE_MODE = function() end,
    },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

local media_cache = require("core.media.media_cache")

print("=== Test media_cache multi-reader LRU pool ===")
print()

--------------------------------------------------------------------------------
-- Test 1: Module has new pool API
--------------------------------------------------------------------------------
print("Test 1: Pool API present")

assert(media_cache.activate, "media_cache.activate missing")
assert(media_cache.reader_pool, "media_cache.reader_pool missing")
assert(media_cache.max_readers, "media_cache.max_readers missing")
assert(media_cache.max_readers == 4, string.format(
    "max_readers should be 4, got %d", media_cache.max_readers))

print("  OK: Pool API present")

--------------------------------------------------------------------------------
-- Test 2: activate() opens reader on first call
--------------------------------------------------------------------------------
print("Test 2: activate() opens reader on first call")

media_cache.activate("/test/clip_a.mov")

assert(media_cache.is_loaded(), "Should be loaded after activate")
assert(media_cache.active_path == "/test/clip_a.mov",
    "active_path should be /test/clip_a.mov")
assert(media_cache.reader_pool["/test/clip_a.mov"],
    "Pool should contain /test/clip_a.mov")

local entry_a = media_cache.reader_pool["/test/clip_a.mov"]
assert(entry_a.video_asset, "Pool entry should have video_asset")
assert(entry_a.video_reader, "Pool entry should have video_reader")
assert(entry_a.audio_asset, "Pool entry should have audio_asset")
assert(entry_a.audio_reader, "Pool entry should have audio_reader")
assert(entry_a.info, "Pool entry should have info")
assert(entry_a.last_used, "Pool entry should have last_used")

print("  OK: activate() opens and pools reader")

--------------------------------------------------------------------------------
-- Test 3: activate() same path is no-op
--------------------------------------------------------------------------------
print("Test 3: activate() same path is no-op")

local prev_asset_count = asset_counter
media_cache.activate("/test/clip_a.mov")
assert(asset_counter == prev_asset_count,
    "activate() same path should not open new assets")

print("  OK: activate() same path is no-op")

--------------------------------------------------------------------------------
-- Test 4: activate() different path opens new reader, pools old
--------------------------------------------------------------------------------
print("Test 4: activate() switches active reader")

media_cache.activate("/test/clip_b.mov")

assert(media_cache.active_path == "/test/clip_b.mov",
    "active_path should be /test/clip_b.mov")
assert(media_cache.reader_pool["/test/clip_b.mov"],
    "Pool should contain /test/clip_b.mov")
-- Old reader stays in pool
assert(media_cache.reader_pool["/test/clip_a.mov"],
    "Pool should still contain /test/clip_a.mov")

print("  OK: activate() switches active reader, old stays pooled")

--------------------------------------------------------------------------------
-- Test 5: get_video_frame works with active reader
--------------------------------------------------------------------------------
print("Test 5: get_video_frame uses active reader")

decode_calls = {}
local frame = media_cache.get_video_frame(42)
assert(frame, "get_video_frame should return a frame")
assert(#decode_calls == 1, "Should have 1 decode call")
assert(decode_calls[1].frame_idx == 42, "Should decode frame 42")

print("  OK: get_video_frame works with active reader")

--------------------------------------------------------------------------------
-- Test 6: LRU eviction when pool full (max_readers=4)
--------------------------------------------------------------------------------
print("Test 6: LRU eviction at max_readers")

-- Already have clip_a and clip_b. Add clip_c and clip_d to fill pool.
media_cache.activate("/test/clip_c.mov")
media_cache.activate("/test/clip_d.mov")

-- Pool should have 4 readers now
local pool_count = 0
for _ in pairs(media_cache.reader_pool) do pool_count = pool_count + 1 end
assert(pool_count == 4, string.format("Pool should have 4, got %d", pool_count))

-- Now activate a 5th — should evict the LRU (clip_a, earliest last_used)
local pre_close_count = #closed_readers
media_cache.activate("/test/clip_e.mov")

pool_count = 0
for _ in pairs(media_cache.reader_pool) do pool_count = pool_count + 1 end
assert(pool_count == 4, string.format("Pool should still be 4 after eviction, got %d", pool_count))
assert(not media_cache.reader_pool["/test/clip_a.mov"],
    "clip_a should have been evicted (LRU)")
assert(media_cache.reader_pool["/test/clip_e.mov"],
    "clip_e should be in pool")

-- Verify resources were closed for evicted reader
assert(#closed_readers > pre_close_count,
    "Eviction should close readers")

print("  OK: LRU eviction works correctly")

--------------------------------------------------------------------------------
-- Test 7: Re-activate evicted path opens fresh reader
--------------------------------------------------------------------------------
print("Test 7: Re-activate evicted path opens fresh")

media_cache.activate("/test/clip_a.mov")
assert(media_cache.reader_pool["/test/clip_a.mov"],
    "clip_a should be back in pool")
assert(media_cache.active_path == "/test/clip_a.mov",
    "active_path should be clip_a")

print("  OK: Re-activate evicted path opens fresh")

--------------------------------------------------------------------------------
-- Test 8: cleanup() releases all pooled readers
--------------------------------------------------------------------------------
print("Test 8: cleanup() releases all")

local pre_cleanup_closed = #closed_readers
media_cache.cleanup()

assert(not media_cache.is_loaded(), "Should not be loaded after cleanup")
assert(media_cache.active_path == nil, "active_path should be nil after cleanup")

pool_count = 0
for _ in pairs(media_cache.reader_pool) do pool_count = pool_count + 1 end
assert(pool_count == 0, string.format("Pool should be empty after cleanup, got %d", pool_count))

assert(#closed_readers > pre_cleanup_closed,
    "cleanup should close all readers")

print("  OK: cleanup() releases all pooled readers")

--------------------------------------------------------------------------------
-- Test 9: get_asset_info returns active reader's info
--------------------------------------------------------------------------------
print("Test 9: get_asset_info returns active reader's info")

media_cache.activate("/test/info_test.mov")
local info = media_cache.get_asset_info()
assert(info, "get_asset_info should return info for active reader")
assert(info.width == 1920, "Info should have correct width")
assert(info.fps_num == 24, "Info should have correct fps_num")

media_cache.cleanup()

print("  OK: get_asset_info works with pool")

--------------------------------------------------------------------------------
print()
print("OK test_media_cache_pool.lua passed")
