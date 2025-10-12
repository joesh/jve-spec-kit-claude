#!/usr/bin/env luajit
-- Test suite for media_reader module
-- Validates FFprobe integration and metadata extraction

package.path = package.path .. ";./src/lua/?.lua;./src/lua/models/?.lua"

-- Test framework
local tests_run = 0
local tests_passed = 0
local tests_failed = 0
local current_test = ""

local function assert_eq(actual, expected, message)
    tests_run = tests_run + 1
    if actual == expected then
        tests_passed = tests_passed + 1
        print(string.format("  ✓ %s: %s", current_test, message))
        return true
    else
        tests_failed = tests_failed + 1
        print(string.format("  ✗ %s: %s", current_test, message))
        print(string.format("    Expected: %s", tostring(expected)))
        print(string.format("    Actual:   %s", tostring(actual)))
        return false
    end
end

local function assert_not_nil(value, message)
    tests_run = tests_run + 1
    if value ~= nil then
        tests_passed = tests_passed + 1
        print(string.format("  ✓ %s: %s", current_test, message))
        return true
    else
        tests_failed = tests_failed + 1
        print(string.format("  ✗ %s: %s (value was nil)", current_test, message))
        return false
    end
end

local function assert_true(condition, message)
    tests_run = tests_run + 1
    if condition then
        tests_passed = tests_passed + 1
        print(string.format("  ✓ %s: %s", current_test, message))
        return true
    else
        tests_failed = tests_failed + 1
        print(string.format("  ✗ %s: %s", current_test, message))
        return false
    end
end

-- Initialize random seed
math.randomseed(os.time() + os.clock() * 1000000)

-- Load media_reader module
local media_reader = require("media.media_reader")

print("=" .. string.rep("=", 59))
print("MEDIA READER TEST SUITE")
print("=" .. string.rep("=", 59))

-- ============================================================================
-- TEST 1: Create test video file using FFmpeg
-- ============================================================================
current_test = "Test 1"
print("\n" .. current_test .. ": Generate test video file")

-- Generate a simple test video: 5 seconds, 1920x1080, 30fps, with audio
local test_video_path = "/tmp/test_video_jve.mp4"
local ffmpeg_cmd = string.format(
    'ffmpeg -f lavfi -i testsrc=duration=5:size=1920x1080:rate=30 ' ..
    '-f lavfi -i sine=frequency=440:duration=5 ' ..
    '-c:v libx264 -pix_fmt yuv420p -c:a aac ' ..
    '-y "%s" 2>/dev/null',
    test_video_path
)

print("  Generating test video with FFmpeg...")
local success = os.execute(ffmpeg_cmd)
assert_true(success, "Test video generated successfully")

-- ============================================================================
-- TEST 2: Probe test video file
-- ============================================================================
current_test = "Test 2"
print("\n" .. current_test .. ": Probe test video file")

local metadata, err = media_reader.probe_file(test_video_path)

if not metadata then
    print("  ERROR: " .. (err or "unknown error"))
else
    assert_not_nil(metadata, "Metadata returned")
    assert_eq(metadata.file_path, test_video_path, "File path matches")
    assert_true(metadata.duration_ms > 4000 and metadata.duration_ms < 6000,
                string.format("Duration ~5000ms (actual: %dms)", metadata.duration_ms))
    assert_eq(metadata.has_video, true, "Has video stream")
    assert_eq(metadata.has_audio, true, "Has audio stream")

    if metadata.video then
        assert_eq(metadata.video.width, 1920, "Video width 1920px")
        assert_eq(metadata.video.height, 1080, "Video height 1080px")
        assert_true(metadata.video.frame_rate > 29 and metadata.video.frame_rate < 31,
                    string.format("Frame rate ~30fps (actual: %.2f)", metadata.video.frame_rate))
        assert_eq(metadata.video.codec, "h264", "Video codec is h264")
    end

    if metadata.audio then
        assert_eq(metadata.audio.channels, 1, "Audio channels (mono)")
        -- FFprobe returns sample_rate as string, need to convert
        assert_eq(tonumber(metadata.audio.sample_rate), 44100, "Audio sample rate 44.1kHz")
        assert_eq(metadata.audio.codec, "aac", "Audio codec is AAC")
    end
end

-- ============================================================================
-- TEST 3: Error handling - nonexistent file
-- ============================================================================
current_test = "Test 3"
print("\n" .. current_test .. ": Error handling for nonexistent file")

local metadata_bad, err_bad = media_reader.probe_file("/tmp/nonexistent_file_xyz.mp4")
assert_eq(metadata_bad, nil, "Returns nil for nonexistent file")
assert_not_nil(err_bad, "Returns error message")
print(string.format("  Error message: %s", err_bad))

-- ============================================================================
-- TEST 4: Error handling - empty path
-- ============================================================================
current_test = "Test 4"
print("\n" .. current_test .. ": Error handling for empty path")

local metadata_empty, err_empty = media_reader.probe_file("")
assert_eq(metadata_empty, nil, "Returns nil for empty path")
assert_not_nil(err_empty, "Returns error message")

-- ============================================================================
-- TEST 5: Generate audio-only test file
-- ============================================================================
current_test = "Test 5"
print("\n" .. current_test .. ": Probe audio-only file")

local test_audio_path = "/tmp/test_audio_jve.wav"
local ffmpeg_audio_cmd = string.format(
    'ffmpeg -f lavfi -i sine=frequency=440:duration=3 ' ..
    '-c:a pcm_s16le -y "%s" 2>/dev/null',
    test_audio_path
)

print("  Generating audio-only test file...")
os.execute(ffmpeg_audio_cmd)

local audio_metadata, audio_err = media_reader.probe_file(test_audio_path)
if audio_metadata then
    assert_eq(audio_metadata.has_video, false, "No video stream")
    assert_eq(audio_metadata.has_audio, true, "Has audio stream")
    assert_true(audio_metadata.duration_ms > 2500 and audio_metadata.duration_ms < 3500,
                string.format("Duration ~3000ms (actual: %dms)", audio_metadata.duration_ms))
end

-- ============================================================================
-- TEST 6: Import media to mock database
-- ============================================================================
current_test = "Test 6"
print("\n" .. current_test .. ": Import media to database")

-- Mock database that captures save operations
local mock_db = {
    saved_media = {}
}

-- Mock Media model
package.loaded["models.media"] = {
    create = function(params)
        return {
            id = params.id,
            project_id = params.project_id,
            name = params.name,
            file_path = params.file_path,
            duration = params.duration,
            frame_rate = params.frame_rate,
            width = params.width,
            height = params.height,
            audio_channels = params.audio_channels,
            created_at = params.created_at,
            modified_at = params.modified_at,
            save = function(self, db)
                table.insert(db.saved_media, self)
                return true
            end
        }
    end
}

local media_id, import_err = media_reader.import_media(test_video_path, mock_db, "test_project")
assert_not_nil(media_id, "Media ID returned")
assert_eq(#mock_db.saved_media, 1, "One media record saved to database")

if #mock_db.saved_media > 0 then
    local saved = mock_db.saved_media[1]
    assert_eq(saved.file_path, test_video_path, "File path stored correctly")
    assert_true(saved.duration > 4000 and saved.duration < 6000, "Duration stored correctly")
    assert_eq(saved.width, 1920, "Width stored correctly")
    assert_eq(saved.height, 1080, "Height stored correctly")
end

-- ============================================================================
-- TEST 7: Batch import
-- ============================================================================
current_test = "Test 7"
print("\n" .. current_test .. ": Batch import multiple files")

local batch_db = {saved_media = {}}
local results = media_reader.batch_import_media(
    {test_video_path, test_audio_path, "/tmp/nonexistent.mp4"},
    batch_db,
    "test_project"
)

assert_eq(#results.success, 2, "Two files imported successfully")
assert_eq(#results.failed, 1, "One file failed")
assert_eq(#batch_db.saved_media, 2, "Two media records in database")

-- ============================================================================
-- Cleanup
-- ============================================================================
print("\nCleaning up test files...")
os.remove(test_video_path)
os.remove(test_audio_path)

-- ============================================================================
-- SUMMARY
-- ============================================================================
print("\n" .. string.rep("=", 60))
print("TEST SUMMARY")
print(string.rep("=", 60))
print(string.format("Total Tests:  %d", tests_run))
print(string.format("Passed:       %d (%.1f%%)", tests_passed, (tests_passed / tests_run) * 100))
print(string.format("Failed:       %d (%.1f%%)", tests_failed, (tests_failed / tests_run) * 100))

if tests_failed == 0 then
    print("\n✅ ALL TESTS PASSED!")
    os.exit(0)
else
    print("\n❌ SOME TESTS FAILED!")
    os.exit(1)
end
