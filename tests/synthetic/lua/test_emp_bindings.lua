-- Test EMP (Editor Media Platform) Lua bindings
-- NOTE: EMP bindings require C++ Qt context. This test runs in application context only.
require('test_env')

print("Testing EMP Lua bindings...")

-- Skip if qt_constants not available (standalone Lua tests)
if not qt_constants then
    print("  ⚠ Skipping: qt_constants not available (requires C++ Qt context)")
    print("✅ test_emp_bindings.lua passed (skipped - no Qt context)")
    return
end

-- Test 1: EMP table exists
assert(qt_constants.EMP, "EMP table should exist in qt_constants")
assert(qt_constants.EMP.MEDIA_FILE_OPEN, "MEDIA_FILE_OPEN should exist")
assert(qt_constants.EMP.READER_CREATE, "READER_CREATE should exist")
assert(qt_constants.EMP.READER_DECODE_FRAME, "READER_DECODE_FRAME should exist")
assert(qt_constants.EMP.FRAME_INFO, "FRAME_INFO should exist")
assert(qt_constants.EMP.SURFACE_SET_FRAME, "SURFACE_SET_FRAME should exist")
print("  ✓ EMP binding functions exist")

-- Test 2: Opening non-existent file returns error (not crash)
local media_file, err = qt_constants.EMP.MEDIA_FILE_OPEN("/nonexistent/file.mp4")
assert(media_file == nil, "Should return nil for non-existent file")
assert(err ~= nil, "Should return error table")
assert(err.code == "FileNotFound", "Error code should be FileNotFound, got: " .. tostring(err.code))
assert(err.msg ~= nil, "Error should have message")
print("  ✓ FileNotFound error returned correctly for missing file")

-- Test 3: Invalid media file handle errors are caught
local status = pcall(function()
    -- Try to get info on nil handle
    return qt_constants.EMP.MEDIA_FILE_INFO(nil)
end)
assert(not status, "MEDIA_FILE_INFO(nil) should fail")
print("  ✓ Invalid handle errors caught")

-- Test 4: VIDEO_SURFACE can be created
if qt_constants.WIDGET.CREATE_VIDEO_SURFACE then
    -- Note: We can't test actual widget creation in headless mode,
    -- but we can verify the function exists
    print("  ✓ CREATE_VIDEO_SURFACE function exists")
else
    print("  ⚠ CREATE_VIDEO_SURFACE not registered (may be headless)")
end

print("✅ test_emp_bindings.lua passed")
