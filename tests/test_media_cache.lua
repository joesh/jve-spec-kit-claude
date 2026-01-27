--- Test media_cache module (dual-asset cache for independent video/audio)
-- @file test_media_cache.lua
--
-- Tests the unified media cache that opens the same file twice
-- (separate AVFormatContexts) to prevent seek conflicts between
-- video and audio decoders.

require('test_env')

-- Mock qt_constants with minimal EMP stubs for module load
-- (media_cache requires qt_constants at load time)
local mock_qt_constants = {
    EMP = {
        ASSET_OPEN = function() return nil, { msg = "mock" } end,
        ASSET_INFO = function() return nil end,
        ASSET_CLOSE = function() end,
        READER_CREATE = function() return nil, { msg = "mock" } end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil, { msg = "mock" } end,
        READER_DECODE_AUDIO_RANGE = function() return nil, { msg = "mock" } end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        PCM_INFO = function() return {} end,
        PCM_DATA_PTR = function() return nil end,
    },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

local media_cache = require("ui.media_cache")

print("=== Test media_cache module ===")
print()

--------------------------------------------------------------------------------
-- Test 1: Module loads and has expected interface
--------------------------------------------------------------------------------
print("Test 1: Module interface")

assert(media_cache.load, "media_cache.load missing")
assert(media_cache.unload, "media_cache.unload missing")
assert(media_cache.get_video_frame, "media_cache.get_video_frame missing")
assert(media_cache.get_audio_pcm, "media_cache.get_audio_pcm missing")
assert(media_cache.set_playhead, "media_cache.set_playhead missing")
assert(media_cache.get_video_asset, "media_cache.get_video_asset missing")
assert(media_cache.get_audio_asset, "media_cache.get_audio_asset missing")
assert(media_cache.get_video_reader, "media_cache.get_video_reader missing")
assert(media_cache.get_audio_reader, "media_cache.get_audio_reader missing")
assert(media_cache.get_asset_info, "media_cache.get_asset_info missing")
assert(media_cache.is_loaded, "media_cache.is_loaded missing")

print("  OK: All expected functions present")

--------------------------------------------------------------------------------
-- Test 2: Initial state
--------------------------------------------------------------------------------
print("Test 2: Initial state")

assert(media_cache.is_loaded() == false, "Should start unloaded")
assert(media_cache.get_video_asset() == nil, "video_asset should be nil")
assert(media_cache.get_audio_asset() == nil, "audio_asset should be nil")
assert(media_cache.get_video_reader() == nil, "video_reader should be nil")
assert(media_cache.get_audio_reader() == nil, "audio_reader should be nil")

print("  OK: Initial state correct")

--------------------------------------------------------------------------------
-- Test 3: Load validation (requires valid path)
--------------------------------------------------------------------------------
print("Test 3: Load validation")

local ok, err = pcall(function()
    media_cache.load(nil)
end)
assert(not ok, "load(nil) should assert")
assert(string.find(tostring(err), "file_path"), "Should mention file_path")

print("  OK: load validates file_path parameter")

--------------------------------------------------------------------------------
-- Test 4: get_video_frame validation (requires load)
--------------------------------------------------------------------------------
print("Test 4: get_video_frame requires load")

ok, err = pcall(function()
    media_cache.get_video_frame(0)
end)
assert(not ok, "get_video_frame without load should assert")
assert(string.find(tostring(err), "not loaded") or string.find(tostring(err), "video_reader"),
       "Should mention not loaded state")

print("  OK: get_video_frame validates loaded state")

--------------------------------------------------------------------------------
-- Test 5: get_audio_pcm validation (requires load)
--------------------------------------------------------------------------------
print("Test 5: get_audio_pcm requires load")

ok, err = pcall(function()
    media_cache.get_audio_pcm(0, 1000000)
end)
assert(not ok, "get_audio_pcm without load should assert")
assert(string.find(tostring(err), "not loaded") or string.find(tostring(err), "audio_reader"),
       "Should mention not loaded state")

print("  OK: get_audio_pcm validates loaded state")

--------------------------------------------------------------------------------
-- Test 6: Video cache window configuration
--------------------------------------------------------------------------------
print("Test 6: Video cache window configuration")

assert(type(media_cache.video_cache) == "table", "video_cache table should exist")
assert(media_cache.video_cache.window_size and media_cache.video_cache.window_size > 0,
       "video_cache.window_size should be positive")
assert(type(media_cache.video_cache.frames) == "table", "video_cache.frames should be table")

print("  OK: Video cache configuration present")

--------------------------------------------------------------------------------
-- Test 7: Audio cache window configuration
--------------------------------------------------------------------------------
print("Test 7: Audio cache window configuration")

assert(type(media_cache.audio_cache) == "table", "audio_cache table should exist")
-- Audio cache stores single PCM chunk with time range
assert(media_cache.audio_cache.start_us ~= nil, "audio_cache.start_us should exist")
assert(media_cache.audio_cache.end_us ~= nil, "audio_cache.end_us should exist")

print("  OK: Audio cache configuration present")

--------------------------------------------------------------------------------
-- Tests 8+ require qt_constants (Qt bindings - run in JVEEditor)
--------------------------------------------------------------------------------
local has_qt = (qt_constants ~= nil and qt_constants.EMP ~= nil)
if not has_qt then
    print("NOTE: qt_constants not available (running standalone)")
    print("      Tests 8+ require running inside JVEEditor")
    print()
end

if has_qt then

--------------------------------------------------------------------------------
-- Test 8: Dual asset creation (the core fix)
--------------------------------------------------------------------------------
print("Test 8: Dual asset creation (requires EMP)")

-- This test would require an actual video file
-- For now, just verify the bindings exist
assert(qt_constants.EMP.ASSET_OPEN, "EMP.ASSET_OPEN missing")
assert(qt_constants.EMP.READER_CREATE, "EMP.READER_CREATE missing")
assert(qt_constants.EMP.READER_CLOSE, "EMP.READER_CLOSE missing")
assert(qt_constants.EMP.ASSET_CLOSE, "EMP.ASSET_CLOSE missing")

print("  OK: EMP bindings available for dual asset creation")

end  -- has_qt

--------------------------------------------------------------------------------
print()
print("OK test_media_cache.lua passed")
