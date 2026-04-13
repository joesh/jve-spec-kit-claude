-- Test: EMP set_tc_origin_override integration
--
-- Requires --test mode (full C++ bindings).
-- Verifies:
-- 1. After calling SET_TC_ORIGIN_OVERRIDE, MEDIA_FILE_INFO reflects the overridden TC
-- 2. The override setter must be callable before any decode
-- 3. Calling the setter after decode has begun must assert
--
-- Uses a real fixture file from tests/fixtures/media/ with a known container TC.

local EMP = qt_constants and qt_constants.EMP
assert(EMP, "EMP bindings not available — run via: ./build/bin/JVEEditor --test this_script.lua")

print("=== test_emp_tc_override.lua ===")

-- Find a fixture file with a known TC
local fixture_dir = "tests/fixtures/media/anamnesis"
local test_file = nil

-- Use any available .mov or .mxf in the fixture tree
local f = io.popen('find "' .. fixture_dir .. '" -name "*.mov" -o -name "*.mxf" 2>/dev/null | head -1')
if f then
    test_file = f:read("*l")
    f:close()
end

if not test_file or test_file == "" then
    print("  ⚠ No fixture media files found in " .. fixture_dir)
    print("  Skipping test (fixture tree not populated)")
    print("\n✅ test_emp_tc_override.lua skipped (no fixtures)")
    return
end
print("  Using fixture: " .. test_file)

-- ─────────────────────────────────────────────────────────────
-- Test 1: Override replaces probed first_frame_tc
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 1: Override replaces probed first_frame_tc ---")

assert(EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE,
    "EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE binding not found (T011 not implemented yet?)")

local mf = EMP.MEDIA_FILE_OPEN(test_file)
assert(mf, "Failed to open fixture file: " .. test_file)

local info_before = EMP.MEDIA_FILE_INFO(mf)
assert(info_before, "MEDIA_FILE_INFO returned nil")

local probed_video_tc = info_before.first_frame_tc
local probed_audio_tc = info_before.first_sample_tc
print(string.format("  Probed: first_frame_tc=%d first_sample_tc=%d",
    probed_video_tc or -1, probed_audio_tc or -1))

-- Override with a known value that differs from probed
local override_video = 1194321  -- 13:16:12:21 at 25fps
local override_audio = 2293096320  -- equivalent at 48kHz

EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE(mf, override_video, override_audio)

local info_after = EMP.MEDIA_FILE_INFO(mf)
assert(info_after.first_frame_tc == override_video, string.format(
    "first_frame_tc should be %d after override, got %d",
    override_video, info_after.first_frame_tc))
assert(info_after.first_sample_tc == override_audio, string.format(
    "first_sample_tc should be %d after override, got %d",
    override_audio, info_after.first_sample_tc))
print(string.format("  ✓ After override: first_frame_tc=%d first_sample_tc=%d",
    info_after.first_frame_tc, info_after.first_sample_tc))

EMP.MEDIA_FILE_CLOSE(mf)

-- ─────────────────────────────────────────────────────────────
-- Test 2: Override with same value as probed (camera footage, no-op)
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 2: Override with probed value (no-op) ---")

local mf2 = EMP.MEDIA_FILE_OPEN(test_file)
assert(mf2, "Failed to open fixture file again")

local info2 = EMP.MEDIA_FILE_INFO(mf2)
-- Override with the probed value itself — should be a no-op
EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE(mf2, info2.first_frame_tc, info2.first_sample_tc)

local info2_after = EMP.MEDIA_FILE_INFO(mf2)
assert(info2_after.first_frame_tc == info2.first_frame_tc,
    "No-op override should not change first_frame_tc")
print("  ✓ No-op override leaves first_frame_tc unchanged")

EMP.MEDIA_FILE_CLOSE(mf2)

-- ─────────────────────────────────────────────────────────────
-- Test 3: Override after decode should assert
-- (This test verifies the assert fires — we catch it with pcall)
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 3: Override after decode asserts ---")

-- NOTE: This test requires creating a Reader and decoding a frame,
-- which is only possible in --test mode with a valid video file.
-- The assertion fires inside C++, caught by Lua's pcall.
-- If the file can't decode (offline, codec unavailable), skip this sub-test.

local mf3 = EMP.MEDIA_FILE_OPEN(test_file)
assert(mf3, "Failed to open fixture file for decode test")

-- Try to create a reader and decode one frame
local reader_ok = true
local reader
if EMP.READER_CREATE then
    local ok, result = pcall(EMP.READER_CREATE, mf3)
    if ok and result then
        reader = result
        -- Attempt one decode to mark decode_started
        if EMP.READER_DECODE_VIDEO then
            pcall(EMP.READER_DECODE_VIDEO, reader, 0)  -- frame 0
        end
    else
        reader_ok = false
    end
else
    reader_ok = false
end

if reader_ok and reader then
    -- Now calling the setter should fail
    local ok, err = pcall(EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE, mf3, 12345, 67890)
    assert(not ok, "SET_TC_ORIGIN_OVERRIDE after decode MUST assert (but it succeeded)")
    print("  ✓ Override after decode asserted: " .. tostring(err):sub(1, 80))
    if reader and EMP.READER_CLOSE then
        pcall(EMP.READER_CLOSE, reader)
    end
else
    print("  ⚠ Skipped decode-then-override test (reader creation failed or unavailable)")
end

EMP.MEDIA_FILE_CLOSE(mf3)

print("\n✅ test_emp_tc_override.lua passed")
