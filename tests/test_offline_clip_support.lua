--- Test offline clip support
-- @file test_offline_clip_support.lua
--
-- Tests:
-- 1. media_cache offline registry: MEDIA_FILE_OPEN fail → nil + registry entry
-- 2. media_cache.activate: offline path → nil return
-- 3. media_cache.ensure_audio_pooled: offline path → nil return
-- 4. media_cache.pre_buffer: offline path → early return
-- 5. Renderer: activate nil → offline metadata (not nil,nil)
-- 6. Mixer: ensure_audio_pooled nil → skip clip gracefully
-- 7. Timeline visual: clip.offline → offline colors

require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")

-- ============================================================================
-- Mock EMP bindings
-- ============================================================================
local mock_media_file_counter = 0
local offline_paths = {}  -- paths that will fail MEDIA_FILE_OPEN

local mock_emp = {
    MEDIA_FILE_OPEN = function(path)
        if offline_paths[path] then
            return nil, { code = "FileNotFound", msg = "File not found: " .. path }
        end
        mock_media_file_counter = mock_media_file_counter + 1
        return "media_file_" .. mock_media_file_counter
    end,
    MEDIA_FILE_INFO = function()
        return {
            has_video = true,
            has_audio = true,
            width = 1920, height = 1080,
            fps_num = 24, fps_den = 1,
            duration_us = 10000000,
            audio_sample_rate = 48000,
            audio_channels = 2,
            rotation = 0,
            start_tc = 0,
        }
    end,
    MEDIA_FILE_CLOSE = function() end,
    READER_CREATE = function() return "reader_" .. mock_media_file_counter end,
    READER_CLOSE = function() end,
    READER_STOP_PREFETCH = function() end,
    READER_START_PREFETCH = function() end,
    READER_UPDATE_PREFETCH_TARGET = function() end,
    READER_DECODE_FRAME = function() return "frame_handle" end,
    READER_DECODE_AUDIO_RANGE = function()
        return "pcm_handle"
    end,
    FRAME_RELEASE = function() end,
    PCM_RELEASE = function() end,
    PCM_INFO = function()
        return { start_time_us = 0, frames = 4800 }
    end,
    PCM_DATA_PTR = function() return nil end,
    SET_DECODE_MODE = function() end,
    COMPOSE_OFFLINE_FRAME = function(_png_path, _lines)
        return "offline_frame_handle"
    end,
}

local mock_qt_constants = { EMP = mock_emp }
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

-- ============================================================================
-- Load media_cache (after mocks)
-- ============================================================================
local media_cache = require("core.media.media_cache")

print("=== Test offline clip support ===")
print()

-- ============================================================================
-- Test 1: open_reader returns nil for offline path, populates registry
-- ============================================================================
print("Test 1: open_reader soft-fail + offline registry")

offline_paths["/missing/video.mov"] = true

-- Activate should return nil for offline path (not crash)
local result = media_cache.activate("/missing/video.mov", "test_ctx_1")
assert(result == nil, "Expected nil from activate for offline path, got: " .. tostring(result))

-- Check offline registry
local offline_info = media_cache.get_offline_info("/missing/video.mov")
assert(offline_info, "Expected offline registry entry")
assert(offline_info.error_code == "FileNotFound",
    "Expected error_code=FileNotFound, got: " .. tostring(offline_info.error_code))
assert(offline_info.error_msg:match("File not found"),
    "Expected error_msg to contain 'File not found'")
assert(offline_info.path == "/missing/video.mov",
    "Expected path in offline info")

-- is_loaded should return false for offline context
assert(media_cache.is_loaded("test_ctx_1") == false,
    "is_loaded should be false for context with offline path")

print("  OK: open_reader returns nil, registry populated")

-- ============================================================================
-- Test 2: activate returns nil for previously-failed path (fast path)
-- ============================================================================
print("Test 2: activate fast-path for known offline path")

local result2 = media_cache.activate("/missing/video.mov", "test_ctx_1")
assert(result2 == nil, "Expected nil from second activate call")

print("  OK: fast-path returns nil without re-trying MEDIA_FILE_OPEN")

-- ============================================================================
-- Test 3: activate succeeds for online path
-- ============================================================================
print("Test 3: activate succeeds for online path")

local info = media_cache.activate("/online/video.mov", "test_ctx_1")
assert(info, "Expected info from activate for online path")
assert(info.has_video == true, "Expected has_video=true")
assert(media_cache.is_loaded("test_ctx_1"), "is_loaded should be true after loading online path")

-- No offline info for online path
assert(media_cache.get_offline_info("/online/video.mov") == nil,
    "Online path should not be in offline registry")

print("  OK: online path loads normally")

-- ============================================================================
-- Test 4: ensure_audio_pooled returns nil for offline path
-- ============================================================================
print("Test 4: ensure_audio_pooled nil for offline")

offline_paths["/missing/audio.wav"] = true
local audio_info = media_cache.ensure_audio_pooled("/missing/audio.wav")
assert(audio_info == nil, "Expected nil from ensure_audio_pooled for offline path")
assert(media_cache.get_offline_info("/missing/audio.wav"),
    "Offline path should be registered")

print("  OK: ensure_audio_pooled returns nil")

-- ============================================================================
-- Test 5: pre_buffer returns early for offline path
-- ============================================================================
print("Test 5: pre_buffer returns early for offline")

offline_paths["/missing/prebuf.mov"] = true
-- Should not crash
media_cache.pre_buffer("/missing/prebuf.mov", 0, 24, 1)
assert(media_cache.get_offline_info("/missing/prebuf.mov"),
    "Offline path should be registered by pre_buffer")

print("  OK: pre_buffer handles offline gracefully")

-- ============================================================================
-- Test 5b: MEDIA_FILE_OPEN fails with nil error struct (no error details)
-- ============================================================================
print("Test 5b: MEDIA_FILE_OPEN nil error struct")

-- Override MEDIA_FILE_OPEN to return nil without error struct
local orig_media_file_open = mock_emp.MEDIA_FILE_OPEN
mock_emp.MEDIA_FILE_OPEN = function(path)
    if path == "/missing/nil_error.mov" then
        return nil, nil  -- no error struct at all
    end
    return orig_media_file_open(path)
end

local nil_err_result = media_cache.activate("/missing/nil_error.mov", "test_ctx_1")
assert(nil_err_result == nil, "Expected nil from activate for nil-error path")
local nil_err_info = media_cache.get_offline_info("/missing/nil_error.mov")
assert(nil_err_info, "Expected offline registry entry for nil-error path")
assert(nil_err_info.error_code == "Unknown",
    "Expected error_code=Unknown when no error struct, got: " .. tostring(nil_err_info.error_code))
assert(nil_err_info.error_msg == "unknown error",
    "Expected error_msg='unknown error' when no error struct")

mock_emp.MEDIA_FILE_OPEN = orig_media_file_open

print("  OK: nil error struct handled correctly")

-- ============================================================================
-- Test 5c: MEDIA_FILE_OPEN fails with PermissionDenied (non-FileNotFound)
-- ============================================================================
print("Test 5c: non-FileNotFound error code")

local orig_media_file_open2 = mock_emp.MEDIA_FILE_OPEN
mock_emp.MEDIA_FILE_OPEN = function(path)
    if path == "/restricted/video.mov" then
        return nil, { code = "PermissionDenied", msg = "Permission denied: /restricted/video.mov" }
    end
    return orig_media_file_open2(path)
end

local perm_result = media_cache.activate("/restricted/video.mov", "test_ctx_1")
assert(perm_result == nil, "Expected nil from activate for permission-denied path")
local perm_info = media_cache.get_offline_info("/restricted/video.mov")
assert(perm_info, "Expected offline registry entry for permission-denied path")
assert(perm_info.error_code == "PermissionDenied",
    "Expected error_code=PermissionDenied, got: " .. tostring(perm_info.error_code))

mock_emp.MEDIA_FILE_OPEN = orig_media_file_open2

print("  OK: PermissionDenied error preserved in registry")

-- ============================================================================
-- Test 6: cleanup clears offline registry
-- ============================================================================
print("Test 6: cleanup clears offline registry")

assert(media_cache.get_offline_info("/missing/video.mov"),
    "Should have offline entry before cleanup")
media_cache.cleanup()
assert(media_cache.get_offline_info("/missing/video.mov") == nil,
    "Offline registry should be cleared after cleanup")

print("  OK: cleanup clears registry")

-- ============================================================================
-- Test 7: Renderer returns offline metadata via TMB path
--
-- Renderer now calls TMB_GET_VIDEO_FRAME (not media_cache). TMB reports
-- offline=true in metadata. Renderer delegates to offline_frame_cache.
-- ============================================================================
print("Test 7: Renderer offline metadata (TMB path)")

-- Set up TMB_GET_VIDEO_FRAME to report offline for track 1 at frame 10
mock_emp.TMB_GET_VIDEO_FRAME = function(tmb, track_idx, frame)
    if frame >= 0 and frame < 48 and track_idx == 1 then
        return nil, {
            clip_id = "clip_off",
            media_path = "/missing/offline_clip.mov",
            source_frame = frame,
            rotation = 0,
            offline = true,
            clip_fps_num = 24,
            clip_fps_den = 1,
            clip_start_frame = 0,
            clip_end_frame = 48,
        }
    end
    -- Gap
    return nil, { clip_id = "", offline = false }
end

local renderer = require("core.renderer")
local mock_tmb = "test_offline_tmb"
local frame_handle, metadata = renderer.get_video_frame(mock_tmb, {1}, 10)

-- Frame handle should be non-nil (composited offline frame from offline_frame_cache)
assert(frame_handle ~= nil,
    "Expected non-nil frame_handle for offline clip (composited), got nil")
-- Metadata should contain offline info
assert(metadata, "Expected non-nil metadata for offline clip")
assert(metadata.offline == true, "Expected metadata.offline=true")
assert(metadata.clip_id == "clip_off", "Expected clip_id in offline metadata")
assert(metadata.media_path == "/missing/offline_clip.mov", "Expected media_path in offline metadata")
assert(metadata.clip_start_frame == 0, "Expected clip_start_frame=0")
assert(metadata.clip_end_frame == 48, "Expected clip_end_frame=48")

print("  OK: Renderer returns offline metadata")

-- ============================================================================
-- Test 8: Mixer skips offline audio clips gracefully
-- ============================================================================
print("Test 8: Mixer handles offline audio clips")

-- Set up DB for mixer test (Tests 8-9 need real DB + sequence)
local DB_PATH = "/tmp/jve/test_offline_mixer.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq', 'proj', 'TestTimeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Create audio track + clip for mixer test
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0)
]]))

assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_audio_off', 'proj', '/missing/audio_offline.wav', 'audio_offline', 480000, 48000, 1, 0, 0, 2, 'pcm',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_audio_off', 'proj', 'timeline', 'AudioOffline', 'a1', 'media_audio_off', 0, 96, 0, 96000, 48000, 1, 1, 1,
           strftime('%s','now'), strftime('%s','now'))
]]))

offline_paths["/missing/audio_offline.wav"] = true

local Sequence = require("models.sequence")
local seq = Sequence.load("seq")
assert(seq)

local Mixer = require("core.mixer")
local sources = Mixer.resolve_audio_sources(seq, 10, 24, 1, media_cache)

-- Mixer should return empty sources for offline audio (not crash)
assert(type(sources) == "table", "Expected sources table")
assert(#sources == 0, "Expected 0 sources for offline audio, got: " .. #sources)

print("  OK: Mixer skips offline audio")

-- ============================================================================
-- Test 9: get_offline_info returns nil for unknown paths
-- ============================================================================
print("Test 9: get_offline_info nil for unknown paths")

assert(media_cache.get_offline_info("/nonexistent/path.mov") == nil,
    "get_offline_info should return nil for paths not in registry")

print("  OK: get_offline_info returns nil for unknown paths")

-- ============================================================================
-- Test 10: Renderer returns nil,nil for gap (not offline metadata)
-- ============================================================================
print("Test 10: Renderer gap vs offline distinction")

-- TMB_GET_VIDEO_FRAME at frame 200 returns gap (nil frame, offline=false)
-- (already the default from mock_emp.TMB_GET_VIDEO_FRAME)
local gap_frame, gap_meta = renderer.get_video_frame(mock_tmb, {1}, 200)
assert(gap_frame == nil, "Expected nil frame_handle for gap")
assert(gap_meta == nil, "Expected nil metadata for gap (not offline)")

print("  OK: Gap returns nil,nil as before")

-- ============================================================================
-- Cleanup
-- ============================================================================
media_cache.cleanup()
os.remove(DB_PATH)

print()
print("✅ test_offline_clip_support.lua passed")
