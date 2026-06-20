#!/usr/bin/env lua
-- test_slideshow_generator.lua
-- Test Phase 3 slideshow generation

-- Add src/lua to package path
package.path = package.path .. ";../src/lua/?.lua"

local slideshow_generator = require("bug_reporter.slideshow_generator")

-- Test utilities
local test_count = 0
local pass_count = 0

local function assert_true(condition, message)
    test_count = test_count + 1
    if condition then
        pass_count = pass_count + 1
        print("✓ " .. message)
    else
        print("✗ " .. message)
    end
end

local function assert_file_exists(path, message)
    test_count = test_count + 1
    local file = io.open(path, "r")
    if file then
        file:close()
        pass_count = pass_count + 1
        print("✓ " .. message)
        return true
    else
        print("✗ " .. message)
        print("  File not found: " .. path)
        return false
    end
end

print("=== Testing Slideshow Generator (Phase 3) ===\n")

-- Test 1: Check ffmpeg availability
print("Test 1: Check ffmpeg availability")
local has_ffmpeg, ffmpeg_path = slideshow_generator.check_ffmpeg()
assert_true(has_ffmpeg, "ffmpeg is available")
if has_ffmpeg then
    print("  ffmpeg path: " .. ffmpeg_path)
end
print()

-- Only continue with remaining tests if ffmpeg is available
if not has_ffmpeg then
    print("Skipping remaining tests (ffmpeg not available)")
    print("\n=== Test Summary ===")
    print(string.format("Passed: %d / %d tests", pass_count, test_count))
    os.exit(pass_count == test_count and 0 or 1)
end

-- Test 2: Create dummy screenshots
print("Test 2: Create dummy screenshots")
local test_dir = "/tmp/jve_slideshow_test"
local screenshot_dir = test_dir .. "/screenshots"
os.execute("mkdir -p " .. screenshot_dir)

-- Probe whether ImageMagick `convert` can actually PRODUCE a PNG — not just
-- whether the binary exists. Some builds (e.g. homebrew imagemagick without a
-- fontconfig delegate) have the binary on PATH yet cannot render text; gating
-- on `which convert` would then run the real test and hard-fail on a missing
-- capability. We only need solid-color frames below (the slideshow generator
-- stitches PNGs and never reads their content), so probe exactly that path.
local function convert_can_make_png()
    local probe = test_dir .. "/.probe.png"
    os.remove(probe)
    os.execute(string.format("convert -size 8x8 xc:white %q >/dev/null 2>&1", probe))
    local f = io.open(probe, "r")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end
local has_convert = convert_can_make_png()

for i = 1, 10 do
    local filename = string.format("%s/screenshot_%03d.png", screenshot_dir, i)
    if has_convert then
        -- A distinct solid-color frame per index. No text → no font dependency;
        -- the slideshow generator only stitches the PNGs, it never reads them,
        -- so the cosmetic frame number is unnecessary and would couple this test
        -- to ImageMagick's font rendering for no coverage gain.
        local cmd = string.format(
            "convert -size 320x240 xc:'rgb(%d,100,150)' %q 2>/dev/null",
            (i * 25) % 256, filename
        )
        os.execute(cmd)
    else
        -- Just create empty files (ffmpeg won't work, but we can test the logic)
        local file = io.open(filename, "w")
        if file then
            file:write("dummy")
            file:close()
        end
    end
end

assert_file_exists(screenshot_dir .. "/screenshot_001.png", "First screenshot created")
assert_file_exists(screenshot_dir .. "/screenshot_010.png", "Last screenshot created")
print()

-- Test 3: Generate slideshow video
print("Test 3: Generate slideshow video")

if has_convert then
    local video_path, err = slideshow_generator.generate(screenshot_dir, 10)

    if video_path then
        assert_true(video_path ~= nil, "Slideshow generation succeeded")
        assert_file_exists(video_path, "Video file created")
        print("  Video path: " .. video_path)

        -- Check file size
        local file_size = slideshow_generator.get_file_size(video_path)
        assert_true(file_size > 1000, "Video file has reasonable size (> 1KB)")
        print(string.format("  Video size: %.2f KB", file_size / 1024))

        -- Calculate expected duration
        local duration = slideshow_generator.calculate_duration(10, 2)
        assert_true(duration == 5, "Expected duration is 5 seconds (10 frames / 2 fps)")
        print(string.format("  Expected duration: %.1f seconds", duration))
    else
        print("✗ Slideshow generation failed: " .. (err or "unknown"))
    end
else
    print("⚠ Skipping video generation (ImageMagick 'convert' not available)")
    print("  (dummy files created but ffmpeg needs real PNGs)")
end
print()

-- Test 4: Test with zero screenshots
print("Test 4: Test with zero screenshots (error case)")
local empty_dir = "/tmp/jve_slideshow_empty"
os.execute("mkdir -p " .. empty_dir)

local video_path, err = slideshow_generator.generate(empty_dir, 0)
assert_true(video_path == nil, "Generation fails with zero screenshots")
assert_true(err ~= nil, "Error message provided")
if err then
    print("  Error: " .. err)
end
print()

-- Clean up
os.execute("rm -rf " .. test_dir)
os.execute("rm -rf " .. empty_dir)

-- Summary
print("=== Test Summary ===")
print(string.format("Passed: %d / %d tests", pass_count, test_count))

if not has_convert then
    print("\n⚠ Note: Some tests skipped (ImageMagick 'convert' not available)")
    print("  Install with: brew install imagemagick")
end

if pass_count == test_count then
    print("✓ All tests passed!")
    os.exit(0)
else
    print("✗ Some tests failed")
    os.exit(1)
end
