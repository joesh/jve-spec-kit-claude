--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~78 LOC
-- Volatility: unknown
--
-- @file slideshow_generator.lua
-- Original intent (unreviewed):
-- slideshow_generator.lua
-- Generate MP4 slideshow videos from screenshot sequences using ffmpeg
local utils = require("bug_reporter.utils")
local logger = require("core.logger")
local SlideshowGenerator = {}

-- Check if ffmpeg is available on the system
function SlideshowGenerator.check_ffmpeg()
    local handle = io.popen("which ffmpeg 2>/dev/null")
    if not handle then
        return false, "Could not execute 'which' command"
    end

    local ffmpeg_path = handle:read("*a")
    handle:close()

    if ffmpeg_path and ffmpeg_path ~= "" then
        return true, ffmpeg_path:gsub("\n", "")
    else
        return false, "ffmpeg not found in PATH"
    end
end

--- Generate MP4 slideshow video from sequential screenshots using FFmpeg
-- Creates an MP4 video from numbered screenshots (screenshot_001.png, etc.) using FFmpeg.
-- Video is generated at 2fps (each image shown for 0.5 seconds) with H.264 codec.
-- Requires FFmpeg to be installed and available in PATH.
--
-- @param screenshot_dir string Directory containing screenshot_NNN.png files (required, non-empty)
-- @param screenshot_count number Number of screenshots to include (required, must be > 0)
-- @param output_path string Optional output video path (defaults to screenshot_dir/../slideshow.mp4)
-- @return string|nil Success: Path to generated MP4 file
-- @return nil, string Failure: nil + error message ("ffmpeg not available", "no screenshots", etc.)
-- @usage
--   local video, err = SlideshowGenerator.generate("tests/captures/cap-123/screenshots", 30)
--   if video then
--     print("Generated: " .. video .. " (" .. (file_size / 1024 / 1024) .. " MB)")
--   else
--     print("Failed: " .. err)
--   end
function SlideshowGenerator.generate(screenshot_dir, screenshot_count, output_path)
    -- Validate parameters
    local valid, err = utils.validate_non_empty(screenshot_dir, "screenshot_dir")
    if not valid then
        return nil, err
    end

    if not screenshot_count or screenshot_count == 0 then
        return nil, "No screenshots to process"
    end

    if type(screenshot_count) ~= "number" or screenshot_count < 0 then
        return nil, "screenshot_count must be a positive number"
    end

    -- Check if ffmpeg is available
    local has_ffmpeg, ffmpeg_info = SlideshowGenerator.check_ffmpeg()
    if not has_ffmpeg then
        return nil, "ffmpeg not available: " .. ffmpeg_info
    end

    -- Default output path
    if not output_path then
        -- Remove trailing slash
        local dir = screenshot_dir:gsub("/$", "")
        -- Get parent directory and append slideshow.mp4
        output_path = dir:gsub("/[^/]+$", "") .. "/slideshow.mp4"
    end

    -- Build ffmpeg command
    -- -framerate 2: 2 frames per second (1 image = 0.5 seconds, 2x speed)
    -- -i screenshot_%03d.png: Input pattern
    -- -c:v libx264: H.264 codec
    -- -pix_fmt yuv420p: Compatible pixel format
    -- -y: Overwrite output file
    local cmd = string.format(
        "ffmpeg -framerate 2 -i '%s/screenshot_%%03d.png' " ..
        "-c:v libx264 -pix_fmt yuv420p -y '%s' 2>&1",
        utils.shell_escape(screenshot_dir),
        utils.shell_escape(output_path)
    )

    logger.info("bug_reporter", "Running ffmpeg...")
    logger.debug("bug_reporter", "Command: " .. cmd)

    -- Execute ffmpeg
    local handle = io.popen(cmd)
    if not handle then
        return nil, "Failed to execute ffmpeg command"
    end

    local output = handle:read("*a")
    local success = handle:close()

    -- Check if ffmpeg succeeded
    if not success then
        logger.error("bug_reporter", "ffmpeg output:")
        logger.error("bug_reporter", output)
        return nil, "ffmpeg failed to generate video"
    end

    -- Verify output file was created
    local file = io.open(output_path, "r")
    if not file then
        return nil, "Output video file not found: " .. output_path
    end
    file:close()

    -- Get file size for reporting
    local size = SlideshowGenerator.get_file_size(output_path)
    logger.info("bug_reporter", string.format("Generated %s (%.2f MB)",
        output_path, size / (1024 * 1024)))

    return output_path
end

-- Get file size in bytes
function SlideshowGenerator.get_file_size(path)
    local handle = io.popen("wc -c < '" .. utils.shell_escape(path) .. "' 2>/dev/null")
    if not handle then
        return 0
    end

    local size_str = handle:read("*a")
    handle:close()

    return tonumber(size_str) or 0
end

-- Calculate expected video duration from screenshot count
-- @param screenshot_count: Number of screenshots
-- @param framerate: Frames per second (default 2 for 2x speed)
-- @return: Duration in seconds
function SlideshowGenerator.calculate_duration(screenshot_count, framerate)
    framerate = framerate or 2
    return screenshot_count / framerate
end

return SlideshowGenerator
