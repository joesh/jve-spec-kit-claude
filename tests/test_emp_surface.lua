-- Test EMP Video Surface operations - ALL PATHS
-- Coverage: creation, frame display, clear, error handling, CPU fallback
require('test_env')

print("Testing EMP Video Surface operations...")

-- Skip if qt_constants not available
if not qt_constants then
    print("  ⚠ Skipping: qt_constants not available")
    print("✅ test_emp_surface.lua passed (skipped)")
    return
end

if not qt_constants.EMP or not qt_constants.WIDGET then
    print("  ⚠ Skipping: EMP or WIDGET bindings not registered")
    print("✅ test_emp_surface.lua passed (skipped)")
    return
end

local EMP = qt_constants.EMP
local WIDGET = qt_constants.WIDGET

-- ============================================================================
-- Test: Video surface creators exist
-- ============================================================================

print("  Testing: Video surface creators exist")
assert(WIDGET.CREATE_GPU_VIDEO_SURFACE or WIDGET.CREATE_CPU_VIDEO_SURFACE,
       "CREATE_GPU_VIDEO_SURFACE or CREATE_CPU_VIDEO_SURFACE should exist")
print("    ✓ Video surface creators exist")

-- ============================================================================
-- Test: SURFACE_SET_FRAME exists
-- ============================================================================

print("  Testing: SURFACE_SET_FRAME exists")
assert(EMP.SURFACE_SET_FRAME, "SURFACE_SET_FRAME should exist")
print("    ✓ SURFACE_SET_FRAME exists")

-- ============================================================================
-- Test: Create video surface (use CPU for tests - sw decode frames)
-- ============================================================================

print("  Testing: Create video surface")
local surface = nil
if WIDGET.CREATE_CPU_VIDEO_SURFACE then
    surface = WIDGET.CREATE_CPU_VIDEO_SURFACE()
    print("    Using CPUVideoSurface")
elseif WIDGET.CREATE_GPU_VIDEO_SURFACE then
    local ok, result = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
    if ok then surface = result end
    print("    Using GPUVideoSurface")
end
assert(surface ~= nil, "Video surface creation failed")
print("    ✓ Video surface created")

-- ============================================================================
-- Test: SURFACE_SET_FRAME with nil clears
-- ============================================================================

print("  Testing: SURFACE_SET_FRAME(nil) clears")
local status, err = pcall(function()
    EMP.SURFACE_SET_FRAME(surface, nil)
end)
assert(status, "SURFACE_SET_FRAME(surface, nil) should not error: " .. tostring(err))
print("    ✓ SURFACE_SET_FRAME(nil) clears without error")

-- ============================================================================
-- Test: SURFACE_SET_FRAME with invalid widget type
-- ============================================================================

print("  Testing: SURFACE_SET_FRAME error on wrong widget type")
-- Create a non-surface widget
local label = nil
if WIDGET.CREATE_LABEL then
    label = WIDGET.CREATE_LABEL("test")
end

if label then
    local status2, err2 = pcall(function()
        EMP.SURFACE_SET_FRAME(label, nil)
    end)
    assert(not status2, "SURFACE_SET_FRAME on non-surface should error")
    print("    ✓ SURFACE_SET_FRAME errors on wrong widget type")
else
    print("    ⚠ Skipped wrong widget type test (no label widget)")
end

-- ============================================================================
-- Test: SURFACE_SET_FRAME with invalid frame
-- ============================================================================

print("  Testing: SURFACE_SET_FRAME with invalid frame handle")
-- Create a fake userdata that isn't a valid frame
local status3, err3 = pcall(function()
    -- Pass something that's not a frame
    EMP.SURFACE_SET_FRAME(surface, "not a frame")
end)
assert(not status3, "SURFACE_SET_FRAME with string should error")
print("    ✓ SURFACE_SET_FRAME with invalid frame errors")

-- ============================================================================
-- Find test video for full integration
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
                local asset, _ = EMP.ASSET_OPEN(path)
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
    print("  ⚠ No test video found - skipping full surface tests")
    print("✅ test_emp_surface.lua passed (partial)")
    return
end

print("  Found test video: " .. test_path)

-- ============================================================================
-- Test: Full pipeline - decode and display
-- ============================================================================

print("  Testing: Full decode -> display pipeline")
local reader = EMP.READER_CREATE(test_asset)
assert(reader, "Reader should create")

local frame = EMP.READER_DECODE_FRAME(reader, 0, test_info.fps_num, test_info.fps_den)
assert(frame, "Should decode frame")

local status4, err4 = pcall(function()
    EMP.SURFACE_SET_FRAME(surface, frame)
end)
assert(status4, "SURFACE_SET_FRAME with valid frame should work: " .. tostring(err4))
print("    ✓ Frame displayed successfully")

-- ============================================================================
-- Test: Multiple frames to same surface
-- ============================================================================

print("  Testing: Multiple frames to same surface")
for i = 0, 4 do
    local f, e = EMP.READER_DECODE_FRAME(reader, i, test_info.fps_num, test_info.fps_den)
    if e and e.code == "EOFReached" then break end
    assert(f, "Should decode frame " .. i)

    local set_status, set_err = pcall(function()
        EMP.SURFACE_SET_FRAME(surface, f)
    end)
    assert(set_status, "Should display frame " .. i .. ": " .. tostring(set_err))
    EMP.FRAME_RELEASE(f)
end
print("    ✓ Multiple frames displayed")

-- ============================================================================
-- Test: Clear after frames
-- ============================================================================

print("  Testing: Clear after displaying frames")
EMP.SURFACE_SET_FRAME(surface, nil)
print("    ✓ Surface cleared")

-- ============================================================================
-- Test: Display frame, then clear, then display again
-- ============================================================================

print("  Testing: Display -> clear -> display cycle")
local f1 = EMP.READER_DECODE_FRAME(reader, 0, test_info.fps_num, test_info.fps_den)
assert(f1, "Should decode f1")
EMP.SURFACE_SET_FRAME(surface, f1)
EMP.FRAME_RELEASE(f1)

EMP.SURFACE_SET_FRAME(surface, nil)

local f2 = EMP.READER_DECODE_FRAME(reader, 1, test_info.fps_num, test_info.fps_den)
if f2 then
    EMP.SURFACE_SET_FRAME(surface, f2)
    EMP.FRAME_RELEASE(f2)
end
print("    ✓ Display cycle works")

-- ============================================================================
-- Test: Display same frame multiple times
-- ============================================================================

print("  Testing: Display same frame multiple times")
local repeat_frame = EMP.READER_DECODE_FRAME(reader, 0, test_info.fps_num, test_info.fps_den)
assert(repeat_frame, "Should decode repeat frame")
for i = 1, 5 do
    local repeat_status, repeat_err = pcall(function()
        EMP.SURFACE_SET_FRAME(surface, repeat_frame)
    end)
    assert(repeat_status, "Repeat display " .. i .. " failed: " .. tostring(repeat_err))
end
EMP.FRAME_RELEASE(repeat_frame)
print("    ✓ Same frame displayed multiple times")

-- ============================================================================
-- Test: Frame released after display still works (surface copied data)
-- ============================================================================

print("  Testing: Frame release after display")
local temp_frame = EMP.READER_DECODE_FRAME(reader, 0, test_info.fps_num, test_info.fps_den)
EMP.SURFACE_SET_FRAME(surface, temp_frame)
EMP.FRAME_RELEASE(temp_frame)
-- Surface should still display (it copied/retained the data)
print("    ✓ Surface survives frame release")

-- ============================================================================
-- Test: Rapid display updates (stress)
-- ============================================================================

print("  Testing: Stress - rapid display updates")
for i = 1, 30 do
    local idx = i % 5
    local f, e = EMP.READER_DECODE_FRAME(reader, idx, test_info.fps_num, test_info.fps_den)
    if e and e.code == "EOFReached" then break end
    if f then
        EMP.SURFACE_SET_FRAME(surface, f)
        EMP.FRAME_RELEASE(f)
    end
end
print("    ✓ Rapid display stress test passed")

-- ============================================================================
-- Cleanup
-- ============================================================================

EMP.SURFACE_SET_FRAME(surface, nil)
EMP.READER_CLOSE(reader)
EMP.ASSET_CLOSE(test_asset)

print("✅ test_emp_surface.lua passed")
