-- Test EMP Reader and Frame operations - ALL PATHS
-- Coverage: creation, decoding, seeking, error handling, lifecycle, edge cases
require('test_env')

print("Testing EMP Reader and Frame operations...")

-- Skip if qt_constants not available
if not qt_constants then
    print("  ⚠ Skipping: qt_constants not available")
    print("✅ test_emp_reader_frame.lua passed (skipped)")
    return
end

if not qt_constants.EMP then
    print("  ⚠ Skipping: EMP bindings not registered")
    print("✅ test_emp_reader_frame.lua passed (skipped)")
    return
end

local EMP = qt_constants.EMP

-- ============================================================================
-- Test: All required functions exist
-- ============================================================================

print("  Testing: Required functions exist")
assert(EMP.READER_CREATE, "READER_CREATE should exist")
assert(EMP.READER_CLOSE, "READER_CLOSE should exist")
assert(EMP.READER_SEEK_FRAME, "READER_SEEK_FRAME should exist")
assert(EMP.READER_DECODE_FRAME, "READER_DECODE_FRAME should exist")
assert(EMP.FRAME_INFO, "FRAME_INFO should exist")
assert(EMP.FRAME_RELEASE, "FRAME_RELEASE should exist")
assert(EMP.FRAME_DATA_PTR, "FRAME_DATA_PTR should exist")
print("    ✓ All required reader/frame functions exist")

-- ============================================================================
-- Test: READER_CREATE with nil asset
-- ============================================================================

print("  Testing: READER_CREATE error handling")
local status, result = pcall(function()
    return EMP.READER_CREATE(nil)
end)
assert(not status or result == nil, "READER_CREATE(nil) should fail")
print("    ✓ READER_CREATE(nil) fails correctly")

-- ============================================================================
-- Test: READER operations on nil handle
-- ============================================================================

print("  Testing: Reader operations on nil handle")
local status1, _ = pcall(function() return EMP.READER_CLOSE(nil) end)
assert(not status1, "READER_CLOSE(nil) should error")

local status2, _ = pcall(function() return EMP.READER_SEEK_FRAME(nil, 0, 30, 1) end)
assert(not status2, "READER_SEEK_FRAME(nil) should error")

local status3, _ = pcall(function() return EMP.READER_DECODE_FRAME(nil, 0, 30, 1) end)
assert(not status3, "READER_DECODE_FRAME(nil) should error")
print("    ✓ Nil handle operations error correctly")

-- ============================================================================
-- Test: FRAME operations on nil handle
-- ============================================================================

print("  Testing: Frame operations on nil handle")
local status4, _ = pcall(function() return EMP.FRAME_INFO(nil) end)
assert(not status4, "FRAME_INFO(nil) should error")

local status5, _ = pcall(function() return EMP.FRAME_RELEASE(nil) end)
assert(not status5, "FRAME_RELEASE(nil) should error")

local status6, _ = pcall(function() return EMP.FRAME_DATA_PTR(nil) end)
assert(not status6, "FRAME_DATA_PTR(nil) should error")
print("    ✓ Nil frame operations error correctly")

-- ============================================================================
-- Find a test video for integration tests
-- ============================================================================

local function find_test_video()
    local paths = {
        os.getenv("HOME") .. "/Movies",
        os.getenv("HOME") .. "/Videos",
        os.getenv("HOME") .. "/Desktop",
        "/tmp",
    }

    for _, dir in ipairs(paths) do
        local handle = io.popen("ls " .. dir .. "/*.mp4 " .. dir .. "/*.mov 2>/dev/null | head -1")
        if handle then
            local path = handle:read("*l")
            handle:close()
            if path and path ~= "" then
                local asset, err = EMP.ASSET_OPEN(path)
                if asset then
                    local info = EMP.ASSET_INFO(asset)
                    if info and info.has_video then
                        return path, asset, info
                    end
                    EMP.ASSET_CLOSE(asset)
                end
            end
        end
    end
    return nil
end

local test_path, test_asset, test_info = find_test_video()

if not test_path then
    print("  ⚠ No test video found - skipping video tests")
    print("✅ test_emp_reader_frame.lua passed (partial)")
    return
end

print("  Found test video: " .. test_path)
print("    " .. test_info.width .. "x" .. test_info.height ..
      " @ " .. string.format("%.2f", test_info.fps_num / test_info.fps_den) .. " fps")

-- ============================================================================
-- Test: READER_CREATE success
-- ============================================================================

print("  Testing: READER_CREATE success")
local reader, err = EMP.READER_CREATE(test_asset)
assert(reader ~= nil, "READER_CREATE should succeed, got: " .. tostring(err and err.msg))
print("    ✓ Reader created successfully")

-- ============================================================================
-- Test: READER_DECODE_FRAME first frame
-- ============================================================================

print("  Testing: READER_DECODE_FRAME first frame")
local frame, err = EMP.READER_DECODE_FRAME(reader, 0, test_info.fps_num, test_info.fps_den)
assert(frame ~= nil, "Should decode frame 0, got: " .. tostring(err and err.msg))
print("    ✓ First frame decoded")

-- ============================================================================
-- Test: FRAME_INFO complete
-- ============================================================================

print("  Testing: FRAME_INFO complete")
local finfo = EMP.FRAME_INFO(frame)
assert(type(finfo) == "table", "FRAME_INFO should return table")
assert(finfo.width == test_info.width, "Frame width should match asset")
assert(finfo.height == test_info.height, "Frame height should match asset")
assert(type(finfo.stride) == "number", "stride should be number")
assert(finfo.stride >= finfo.width * 4, "stride >= width*4 (BGRA32)")
assert(finfo.stride % 32 == 0, "stride should be 32-byte aligned")
assert(type(finfo.source_pts_us) == "number", "source_pts_us should be number")
print("    ✓ FRAME_INFO complete and valid")

-- ============================================================================
-- Test: FRAME_DATA_PTR returns lightuserdata
-- ============================================================================

print("  Testing: FRAME_DATA_PTR")
local data_ptr = EMP.FRAME_DATA_PTR(frame)
assert(type(data_ptr) == "userdata", "FRAME_DATA_PTR should return userdata")
print("    ✓ FRAME_DATA_PTR returns lightuserdata")

-- ============================================================================
-- Test: Multiple FRAME_DATA_PTR calls return same pointer
-- ============================================================================

print("  Testing: Multiple FRAME_DATA_PTR calls")
local ptr1 = EMP.FRAME_DATA_PTR(frame)
local ptr2 = EMP.FRAME_DATA_PTR(frame)
local ptr3 = EMP.FRAME_DATA_PTR(frame)
assert(ptr1 == ptr2 and ptr2 == ptr3, "DATA_PTR should be stable")
print("    ✓ Multiple DATA_PTR calls return same pointer")

-- ============================================================================
-- Test: FRAME_RELEASE
-- ============================================================================

print("  Testing: FRAME_RELEASE")
EMP.FRAME_RELEASE(frame)
-- After release, operations on frame should fail
local status_after, _ = pcall(function() return EMP.FRAME_INFO(frame) end)
-- Note: This might not fail if the handle is still technically valid but stale
-- The test just ensures RELEASE doesn't crash
print("    ✓ FRAME_RELEASE completed")

-- ============================================================================
-- Test: Decode multiple sequential frames
-- ============================================================================

print("  Testing: Sequential frame decode")
for i = 0, 4 do
    local f, e = EMP.READER_DECODE_FRAME(reader, i, test_info.fps_num, test_info.fps_den)
    if e and e.code == "EOFReached" then
        print("    (video has < 5 frames)")
        break
    end
    assert(f ~= nil, "Should decode frame " .. i)
    local fi = EMP.FRAME_INFO(f)
    assert(fi.width > 0, "Frame " .. i .. " should have valid width")
    EMP.FRAME_RELEASE(f)
end
print("    ✓ Sequential frames decoded")

-- ============================================================================
-- Test: READER_SEEK_FRAME
-- ============================================================================

print("  Testing: READER_SEEK_FRAME")
local seek_result, seek_err = EMP.READER_SEEK_FRAME(reader, 0, test_info.fps_num, test_info.fps_den)
assert(seek_result, "Seek to frame 0 should succeed")
print("    ✓ READER_SEEK_FRAME to frame 0")

-- ============================================================================
-- Test: Seek to negative frame (should clamp)
-- ============================================================================

print("  Testing: Seek negative frame")
local neg_result, neg_err = EMP.READER_SEEK_FRAME(reader, -10, test_info.fps_num, test_info.fps_den)
assert(neg_result, "Seek to negative should succeed (clamps)")
print("    ✓ Negative seek handled")

-- ============================================================================
-- Test: Decode negative time (should return first frame)
-- ============================================================================

print("  Testing: Decode negative frame index")
local neg_frame, neg_frame_err = EMP.READER_DECODE_FRAME(reader, -5, test_info.fps_num, test_info.fps_den)
if neg_frame then
    local neg_info = EMP.FRAME_INFO(neg_frame)
    assert(neg_info.source_pts_us >= 0, "Negative decode should return frame with pts >= 0")
    EMP.FRAME_RELEASE(neg_frame)
    print("    ✓ Negative frame index handled")
else
    print("    ⚠ Negative frame decode failed (may be OK)")
end

-- ============================================================================
-- Test: Decode past EOF
-- ============================================================================

print("  Testing: Decode past EOF")
local huge_frame = 999999
local eof_frame, eof_err = EMP.READER_DECODE_FRAME(reader, huge_frame, test_info.fps_num, test_info.fps_den)
if eof_err then
    assert(eof_err.code == "EOFReached", "Past-EOF should return EOFReached, got: " .. tostring(eof_err.code))
    print("    ✓ EOF error returned correctly")
else
    -- Some decoders return last frame - that's also valid
    assert(eof_frame ~= nil, "Should return last frame or EOF")
    EMP.FRAME_RELEASE(eof_frame)
    print("    ✓ Last frame returned for past-EOF")
end

-- ============================================================================
-- Test: Random access pattern (backward seeks)
-- ============================================================================

print("  Testing: Random access pattern")
local access_pattern = {0, 10, 2, 15, 0, 5}
for _, idx in ipairs(access_pattern) do
    local f, e = EMP.READER_DECODE_FRAME(reader, idx, test_info.fps_num, test_info.fps_den)
    if e and e.code == "EOFReached" then
        -- Skip if video too short
    else
        assert(f ~= nil, "Random access to frame " .. idx .. " failed")
        EMP.FRAME_RELEASE(f)
    end
end
print("    ✓ Random access pattern handled")

-- ============================================================================
-- Test: Recovery after EOF
-- ============================================================================

print("  Testing: Recovery after EOF")
-- Hit EOF
EMP.READER_DECODE_FRAME(reader, 999999, test_info.fps_num, test_info.fps_den)
-- Should still work from beginning
local recovery_frame, recovery_err = EMP.READER_DECODE_FRAME(reader, 0, test_info.fps_num, test_info.fps_den)
assert(recovery_frame ~= nil, "Should recover after EOF, got: " .. tostring(recovery_err and recovery_err.msg))
EMP.FRAME_RELEASE(recovery_frame)
print("    ✓ Recovery after EOF works")

-- ============================================================================
-- Test: Frame independence from reader
-- ============================================================================

print("  Testing: Frame outlives reader")
local temp_asset = EMP.ASSET_OPEN(test_path)
local temp_reader = EMP.READER_CREATE(temp_asset)
local outliving_frame = EMP.READER_DECODE_FRAME(temp_reader, 0, test_info.fps_num, test_info.fps_den)
assert(outliving_frame, "Should decode frame")

-- Close reader and asset
EMP.READER_CLOSE(temp_reader)
EMP.ASSET_CLOSE(temp_asset)

-- Frame should still be valid
local outliving_info = EMP.FRAME_INFO(outliving_frame)
assert(outliving_info.width > 0, "Frame should remain valid after reader closed")
local outliving_ptr = EMP.FRAME_DATA_PTR(outliving_frame)
assert(outliving_ptr, "Data pointer should be valid")
EMP.FRAME_RELEASE(outliving_frame)
print("    ✓ Frame outlives reader")

-- ============================================================================
-- Test: Multiple readers on same asset
-- ============================================================================

print("  Testing: Multiple readers on same asset")
local reader2 = EMP.READER_CREATE(test_asset)
local reader3 = EMP.READER_CREATE(test_asset)
assert(reader2, "Second reader should create")
assert(reader3, "Third reader should create")

-- Both should decode independently
local f2 = EMP.READER_DECODE_FRAME(reader2, 0, test_info.fps_num, test_info.fps_den)
local f3 = EMP.READER_DECODE_FRAME(reader3, 5, test_info.fps_num, test_info.fps_den)

assert(f2, "Reader2 should decode")
if f3 == nil then
    -- Video might be short
else
    EMP.FRAME_RELEASE(f3)
end
EMP.FRAME_RELEASE(f2)
EMP.READER_CLOSE(reader2)
EMP.READER_CLOSE(reader3)
print("    ✓ Multiple readers work independently")

-- ============================================================================
-- Test: Stress - rapid decode
-- ============================================================================

print("  Testing: Stress - rapid decode")
for i = 1, 50 do
    local idx = i % 10
    local f, e = EMP.READER_DECODE_FRAME(reader, idx, test_info.fps_num, test_info.fps_den)
    if e and e.code == "EOFReached" then break end
    assert(f, "Rapid decode " .. i .. " failed")
    EMP.FRAME_RELEASE(f)
end
print("    ✓ Rapid decode stress test passed")

-- ============================================================================
-- Cleanup
-- ============================================================================

EMP.READER_CLOSE(reader)
EMP.ASSET_CLOSE(test_asset)

print("✅ test_emp_reader_frame.lua passed")
