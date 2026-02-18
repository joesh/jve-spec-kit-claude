#!/usr/bin/env luajit
-- TDD test: media_cache.pre_buffer warms reader pool without changing active context.
-- Uses mocked EMP bindings since real readers require C++.

require('test_env')

print("=== test_pre_buffer_media_cache.lua ===")

-- Mock EMP bindings BEFORE loading media_cache (qt_constants must be in package.loaded)
local decoded_frames = {}  -- { {reader, frame_idx, fps_num, fps_den}, ... }
local mock_reader_counter = 0
local mock_media_file_counter = 0

local mock_emp = {
    MEDIA_FILE_OPEN = function(path)
        mock_media_file_counter = mock_media_file_counter + 1
        return { _id = mock_media_file_counter, _path = path }
    end,
    MEDIA_FILE_CLOSE = function() end,
    MEDIA_FILE_INFO = function()
        return {
            has_video = true,
            has_audio = true,
            width = 1920, height = 1080,
            fps_num = 24, fps_den = 1,
            duration_us = 10000000,
            audio_sample_rate = 48000,
            audio_channels = 2,
        }
    end,
    READER_CREATE = function()
        mock_reader_counter = mock_reader_counter + 1
        return { _id = mock_reader_counter }
    end,
    READER_CLOSE = function() end,
    READER_DECODE_FRAME = function(reader, frame_idx, fps_num, fps_den)
        decoded_frames[#decoded_frames + 1] = {
            reader = reader, frame_idx = frame_idx,
            fps_num = fps_num, fps_den = fps_den,
        }
        return "frame_" .. frame_idx  -- mock frame handle
    end,
    READER_START_PREFETCH = function() end,
    READER_STOP_PREFETCH = function() end,
    READER_UPDATE_PREFETCH_TARGET = function() end,
    FRAME_RELEASE = function() end,
    PCM_RELEASE = function() end,
    SET_DECODE_MODE = function() end,
}

-- Mock signals (media_cache registers for project_changed)
package.loaded["core.signals"] = {
    connect = function() end,
    emit = function() end,
}

-- Install qt_constants mock before any module loads it
package.loaded["core.qt_constants"] = { EMP = mock_emp }

local media_cache = require("core.media.media_cache")

-- Reset state
media_cache.reader_pool = {}
media_cache.contexts = {}

--------------------------------------------------------------------------------
-- Test 1: pre_buffer warms pool without changing active context
--------------------------------------------------------------------------------

print("\n--- pre_buffer warms pool, doesn't change active_path ---")
do
    -- Create a context and activate a different file
    media_cache.create_context("test_ctx")
    media_cache.activate("/test/active.mov", "test_ctx")

    assert(media_cache.get_file_path("test_ctx") == "/test/active.mov",
        "Active path should be /test/active.mov")

    -- Pre-buffer a different file
    decoded_frames = {}
    media_cache.pre_buffer("/test/next_clip.mov", 50, 24, 1)

    -- Active path must NOT change
    assert(media_cache.get_file_path("test_ctx") == "/test/active.mov",
        "Active path must not change after pre_buffer")

    -- But the path should be in the pool
    assert(media_cache.reader_pool["/test/next_clip.mov"],
        "Pre-buffered path should be in reader pool")

    -- Frames should have been decoded
    assert(#decoded_frames >= 1, string.format(
        "Expected decoded frames from pre_buffer, got %d", #decoded_frames))

    -- First decoded frame should be at entry_frame (50)
    assert(decoded_frames[1].frame_idx == 50, string.format(
        "First decoded frame should be 50, got %d", decoded_frames[1].frame_idx))

    -- FPS should be passed through
    assert(decoded_frames[1].fps_num == 24, "fps_num should be 24")
    assert(decoded_frames[1].fps_den == 1, "fps_den should be 1")

    print("  pre_buffer warms pool, active_path unchanged passed")
end

--------------------------------------------------------------------------------
-- Test 2: pre_buffer decodes ~5 frames around entry point
--------------------------------------------------------------------------------

print("\n--- pre_buffer decodes multiple frames ---")
do
    decoded_frames = {}
    media_cache.pre_buffer("/test/another.mov", 100, 30, 1)

    -- Should decode at least 5 frames (100..104)
    assert(#decoded_frames >= 5, string.format(
        "Expected at least 5 decoded frames, got %d", #decoded_frames))

    -- Verify frame indices are contiguous from entry_frame
    for i = 1, 5 do
        assert(decoded_frames[i].frame_idx == 100 + (i - 1), string.format(
            "Frame %d should be %d, got %d", i, 100 + (i - 1), decoded_frames[i].frame_idx))
    end

    print("  pre_buffer decodes 5 contiguous frames passed")
end

--------------------------------------------------------------------------------
-- Test 3: pre_buffer with already-pooled path doesn't re-open
--------------------------------------------------------------------------------

print("\n--- pre_buffer with pooled path reuses existing reader ---")
do
    local pool_count_before = 0
    for _ in pairs(media_cache.reader_pool) do pool_count_before = pool_count_before + 1 end

    local open_count_before = mock_media_file_counter

    -- Pre-buffer a path already in pool
    decoded_frames = {}
    media_cache.pre_buffer("/test/next_clip.mov", 0, 24, 1)

    -- No new media file opens
    assert(mock_media_file_counter == open_count_before, string.format(
        "Should not open new media file, opened %d new", mock_media_file_counter - open_count_before))

    -- Should still decode frames
    assert(#decoded_frames >= 5, "Should decode frames from existing reader")

    print("  pre_buffer reuses existing reader passed")
end

--------------------------------------------------------------------------------
-- Test 4: pre_buffer asserts on nil path
--------------------------------------------------------------------------------

print("\n--- pre_buffer asserts on nil path ---")
do
    local ok, err = pcall(media_cache.pre_buffer, nil, 0, 24, 1)
    assert(not ok, "Should assert on nil path")
    assert(err:find("path"), "Error should mention path, got: " .. err)
    print("  pre_buffer asserts on nil path passed")
end

--------------------------------------------------------------------------------
-- Test 5: pre_buffer asserts on nil entry_frame
--------------------------------------------------------------------------------

print("\n--- pre_buffer asserts on nil entry_frame ---")
do
    local ok, err = pcall(media_cache.pre_buffer, "/test/x.mov", nil, 24, 1)
    assert(not ok, "Should assert on nil entry_frame")
    assert(err:find("entry_frame"), "Error should mention entry_frame, got: " .. err)
    print("  pre_buffer asserts on nil entry_frame passed")
end

-- Cleanup
media_cache.cleanup()

print("\n✅ test_pre_buffer_media_cache.lua passed")
