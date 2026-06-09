-- Test EMP MediaFile operations
-- Tests: MEDIA_FILE_OPEN, MEDIA_FILE_INFO, MEDIA_FILE_CLOSE, error handling
require('test_env')

print("Testing EMP MediaFile operations...")

-- Skip if qt_constants not available (standalone Lua tests)
if not qt_constants then
    print("  ⚠ Skipping: qt_constants not available (requires C++ Qt context)")
    print("✅ test_emp_media_file.lua passed (skipped - no Qt context)")
    return
end

if not qt_constants.EMP then
    print("  ⚠ Skipping: EMP bindings not registered")
    print("✅ test_emp_media_file.lua passed (skipped - no EMP)")
    return
end

local EMP = qt_constants.EMP

-- ============================================================================
-- Test: Required functions exist
-- ============================================================================

print("  Testing: Required functions exist")
assert(EMP.MEDIA_FILE_OPEN, "MEDIA_FILE_OPEN should exist")
assert(EMP.MEDIA_FILE_INFO, "MEDIA_FILE_INFO should exist")
assert(EMP.MEDIA_FILE_CLOSE, "MEDIA_FILE_CLOSE should exist")
print("    ✓ All required media file functions exist")

-- ============================================================================
-- Test: Opening non-existent file returns error
-- ============================================================================

print("  Testing: Non-existent file error")
local media_file, err = EMP.MEDIA_FILE_OPEN("/nonexistent/path/to/video.mp4")
assert(media_file == nil, "Should return nil for non-existent file")
assert(err ~= nil, "Should return error table")
assert(err.code == "FileNotFound", "Error code should be FileNotFound, got: " .. tostring(err.code))
assert(type(err.msg) == "string", "Error should have message string")
print("    ✓ FileNotFound error returned correctly")

-- ============================================================================
-- Test: Opening invalid file returns error
-- ============================================================================

print("  Testing: Invalid file error")
-- Create temp file with invalid content
local tmp_path = "/tmp/jve_test_invalid_video_" .. os.time() .. ".mp4"
local f = io.open(tmp_path, "w")
if f then
    f:write("not a video file")
    f:close()

    local media_file2, err2 = EMP.MEDIA_FILE_OPEN(tmp_path)
    assert(media_file2 == nil, "Should return nil for invalid file")
    assert(err2 ~= nil, "Should return error table")
    -- Error code could be Unsupported or Internal
    assert(err2.code ~= "Ok", "Error code should not be Ok")
    print("    ✓ Invalid file error returned correctly")

    os.remove(tmp_path)
else
    print("    ⚠ Could not create temp file, skipping invalid file test")
end

-- ============================================================================
-- Test: MEDIA_FILE_INFO on nil handle errors
-- ============================================================================

print("  Testing: MEDIA_FILE_INFO error handling")
local status = pcall(function()
    return EMP.MEDIA_FILE_INFO(nil)
end)
assert(not status, "MEDIA_FILE_INFO(nil) should error")
print("    ✓ MEDIA_FILE_INFO(nil) throws error")

-- ============================================================================
-- Test: MEDIA_FILE_CLOSE on nil handle doesn't crash
-- ============================================================================

print("  Testing: MEDIA_FILE_CLOSE error handling")
local status2 = pcall(function()
    return EMP.MEDIA_FILE_CLOSE(nil)
end)
-- Should error but not crash
assert(not status2, "MEDIA_FILE_CLOSE(nil) should error")
print("    ✓ MEDIA_FILE_CLOSE(nil) throws error (doesn't crash)")

-- ============================================================================
-- Test: Opening same file twice works
-- ============================================================================

print("  Testing: Multiple opens of same path")
-- This test requires a real video file
-- We'll attempt to find one but skip if none available
local test_video_paths = {
    os.getenv("HOME") .. "/Movies",
    os.getenv("HOME") .. "/Videos",
    os.getenv("HOME") .. "/Desktop",
    "/tmp",
}

local found_video = nil
for _, dir in ipairs(test_video_paths) do
    local handle = io.popen("ls " .. dir .. "/*.mp4 " .. dir .. "/*.mov 2>/dev/null | head -1")
    if handle then
        local path = handle:read("*l")
        handle:close()
        if path and path ~= "" then
            local test_mf = EMP.MEDIA_FILE_OPEN(path)
            if test_mf then
                EMP.MEDIA_FILE_CLOSE(test_mf)
                found_video = path
                break
            end
        end
    end
end

if found_video then
    local a1 = EMP.MEDIA_FILE_OPEN(found_video)
    local a2 = EMP.MEDIA_FILE_OPEN(found_video)

    assert(a1 ~= nil, "First open should succeed")
    assert(a2 ~= nil, "Second open should succeed")
    assert(a1 ~= a2, "Should be different handles")

    local info1 = EMP.MEDIA_FILE_INFO(a1)
    local info2 = EMP.MEDIA_FILE_INFO(a2)

    assert(info1.width == info2.width, "Same file should have same width")
    assert(info1.height == info2.height, "Same file should have same height")

    EMP.MEDIA_FILE_CLOSE(a1)
    EMP.MEDIA_FILE_CLOSE(a2)
    print("    ✓ Multiple opens work correctly")

    -- ============================================================================
    -- Test: MEDIA_FILE_INFO returns complete info
    -- ============================================================================

    print("  Testing: MEDIA_FILE_INFO completeness")
    local info_mf = EMP.MEDIA_FILE_OPEN(found_video)
    assert(info_mf, "MediaFile should open")

    local info = EMP.MEDIA_FILE_INFO(info_mf)
    assert(type(info) == "table", "Info should be table")
    assert(type(info.path) == "string", "path should be string")
    assert(type(info.has_video) == "boolean", "has_video should be boolean")
    assert(type(info.width) == "number", "width should be number")
    assert(type(info.height) == "number", "height should be number")
    assert(type(info.fps_num) == "number", "fps_num should be number")
    assert(type(info.fps_den) == "number", "fps_den should be number")
    assert(type(info.duration_us) == "number", "duration_us should be number")
    assert(type(info.is_vfr) == "boolean", "is_vfr should be boolean")

    assert(info.has_video == true, "Test video should have video")
    assert(info.width > 0, "Width should be positive")
    assert(info.height > 0, "Height should be positive")
    assert(info.fps_num > 0, "fps_num should be positive")
    assert(info.fps_den > 0, "fps_den should be positive")
    assert(info.duration_us > 0, "duration_us should be positive")

    print("    ✓ MEDIA_FILE_INFO returns complete info")
    print("      Video: " .. info.width .. "x" .. info.height .. " @ " ..
          string.format("%.2f", info.fps_num / info.fps_den) .. " fps")

    EMP.MEDIA_FILE_CLOSE(info_mf)
else
    print("    ⚠ No test video found, skipping real video tests")
end

print("✅ test_emp_media_file.lua passed")
