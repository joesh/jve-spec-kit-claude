--- Test media_cache module (per-context cache with shared reader pool)
-- @file test_media_cache.lua
--
-- Tests the per-context media cache with shared LRU reader pool.
-- Each monitor context (source_monitor, timeline_monitor) has independent
-- active_path, video_cache, and audio_cache state.

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

local media_cache = require("core.media.media_cache")

local CTX = "test_ctx"

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
assert(media_cache.create_context, "media_cache.create_context missing")
assert(media_cache.destroy_context, "media_cache.destroy_context missing")

print("  OK: All expected functions present")

--------------------------------------------------------------------------------
-- Test 2: Initial state (per-context)
--------------------------------------------------------------------------------
print("Test 2: Initial state")

assert(media_cache.is_loaded(CTX) == false, "Should start unloaded")
assert(media_cache.get_video_asset(CTX) == nil, "video_asset should be nil")
assert(media_cache.get_audio_asset(CTX) == nil, "audio_asset should be nil")
assert(media_cache.get_video_reader(CTX) == nil, "video_reader should be nil")
assert(media_cache.get_audio_reader(CTX) == nil, "audio_reader should be nil")

print("  OK: Initial state correct")

--------------------------------------------------------------------------------
-- Test 3: Load validation (requires valid path)
--------------------------------------------------------------------------------
print("Test 3: Load validation")

local ok, err = pcall(function()
    media_cache.load(nil, CTX)
end)
assert(not ok, "load(nil) should assert")
assert(string.find(tostring(err), "file_path"), "Should mention file_path")

print("  OK: load validates file_path parameter")

--------------------------------------------------------------------------------
-- Test 4: get_video_frame validation (requires load)
--------------------------------------------------------------------------------
print("Test 4: get_video_frame requires load")

ok, err = pcall(function()
    media_cache.get_video_frame(0, CTX)
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
    media_cache.get_audio_pcm(0, 1000000, nil, CTX)
end)
assert(not ok, "get_audio_pcm without load should assert")
assert(string.find(tostring(err), "not loaded") or string.find(tostring(err), "audio_reader"),
       "Should mention not loaded state")

print("  OK: get_audio_pcm validates loaded state")

--------------------------------------------------------------------------------
-- Test 6: Context_id is required
--------------------------------------------------------------------------------
print("Test 6: context_id required")

ok, err = pcall(function()
    media_cache.is_loaded()
end)
assert(not ok, "is_loaded() without context_id should assert")
assert(string.find(tostring(err), "context_id"), "Should mention context_id")

print("  OK: context_id is required")

--------------------------------------------------------------------------------
-- Test 7: Explicit context create/destroy
--------------------------------------------------------------------------------
print("Test 7: Context lifecycle")

media_cache.create_context("explicit_ctx")
assert(media_cache.contexts["explicit_ctx"], "Context should exist after create")

media_cache.destroy_context("explicit_ctx")
assert(not media_cache.contexts["explicit_ctx"], "Context should be gone after destroy")

-- Duplicate create asserts
media_cache.create_context("dup_ctx")
local ok2, err2 = pcall(function()
    media_cache.create_context("dup_ctx")
end)
assert(not ok2, "Duplicate create should assert")
assert(err2, "Should have error message")  -- use err2
media_cache.destroy_context("dup_ctx")

-- Destroy non-existent context asserts (catches double-destroy bugs)
ok, err = pcall(function()
    media_cache.destroy_context("nonexistent_ctx")
end)
assert(not ok, "Destroying non-existent context should assert")
assert(string.find(tostring(err), "nonexistent_ctx"),
    "Error should mention the context_id")

print("  OK: Context lifecycle works")

--------------------------------------------------------------------------------
-- Test 8: context_id required on all per-context APIs
--------------------------------------------------------------------------------
print("Test 8: context_id required on all APIs")

local nil_ctx_apis = {
    { "is_loaded",       function() media_cache.is_loaded() end },
    { "get_file_path",   function() media_cache.get_file_path() end },
    { "get_video_asset", function() media_cache.get_video_asset() end },
    { "get_audio_asset", function() media_cache.get_audio_asset() end },
    { "get_video_reader",function() media_cache.get_video_reader() end },
    { "get_audio_reader",function() media_cache.get_audio_reader() end },
    { "get_asset_info",  function() media_cache.get_asset_info() end },
    { "get_rotation",    function() media_cache.get_rotation() end },
}
for _, case in ipairs(nil_ctx_apis) do
    ok, err = pcall(case[2])
    assert(not ok, case[1] .. "() without context_id should assert")
    assert(string.find(tostring(err), "context_id"),
        case[1] .. " error should mention context_id, got: " .. tostring(err))
end

print("  OK: All per-context APIs require context_id")

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

-- Cleanup lazy-created test context
media_cache.cleanup()

--------------------------------------------------------------------------------
print()
print("OK test_media_cache.lua passed")
