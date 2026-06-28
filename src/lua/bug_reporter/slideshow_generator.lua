--- slideshow_generator.lua
-- Generate MP4 slideshow videos from screenshot sequences using ffmpeg
local utils = require("bug_reporter.utils")
local log = require("core.logger").for_area("ui")
local SlideshowGenerator = {}

-- Absolute-path candidates checked in order. Finder-launched .app
-- processes run with a stripped PATH that excludes /opt/homebrew/bin
-- and /usr/local/bin, so `which ffmpeg` returns empty inside JVE
-- launched via Finder/Dock — slideshow generation silently failed
-- (pass 1+2 #3 HIGH). We probe the canonical install locations
-- directly via QFileInfo (qt_fs_path_exists exists for this).
local FFMPEG_CANDIDATES = {
    "/opt/homebrew/bin/ffmpeg",   -- Homebrew (Apple Silicon default)
    "/usr/local/bin/ffmpeg",      -- Homebrew (Intel default)
    "/opt/local/bin/ffmpeg",      -- MacPorts
    "/usr/bin/ffmpeg",            -- system (rare on macOS)
}

local cached_ffmpeg

function SlideshowGenerator.check_ffmpeg()
    if cached_ffmpeg ~= nil then
        if cached_ffmpeg == false then return false, "ffmpeg not found in any canonical path" end
        return true, cached_ffmpeg
    end
    for _, path in ipairs(FFMPEG_CANDIDATES) do
        if qt_fs_path_exists(path) then
            cached_ffmpeg = path
            return true, path
        end
    end
    cached_ffmpeg = false
    return false, "ffmpeg not found in any of: " .. table.concat(FFMPEG_CANDIDATES, ", ")
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

    -- Resolve ffmpeg via absolute path (Finder-launched .app has stripped PATH).
    local has_ffmpeg, ffmpeg_path = SlideshowGenerator.check_ffmpeg()
    if not has_ffmpeg then
        return nil, "ffmpeg not available: " .. ffmpeg_path
    end

    -- Default output path: parent directory of screenshot_dir, slideshow.mp4.
    if not output_path then
        local dir = screenshot_dir:gsub("/$", "")
        output_path = dir:gsub("/[^/]+$", "") .. "/slideshow.mp4"
    end

    local cmd = string.format(
        "%s -framerate 2 -i %s/screenshot_%%03d.png " ..
        "-c:v libx264 -pix_fmt yuv420p -y %s 2>&1",
        utils.shell_quoted_arg(ffmpeg_path),
        utils.shell_quoted_arg(screenshot_dir),
        utils.shell_quoted_arg(output_path)
    )

    log.event("Running ffmpeg...")
    log.event("Command: %s", cmd)

    -- Execute ffmpeg
    local handle = io.popen(cmd)
    if not handle then
        return nil, "Failed to execute ffmpeg command"
    end

    local output = handle:read("*a")
    local success = handle:close()

    -- Check if ffmpeg succeeded
    if not success then
        log.error("ffmpeg output:")
        log.error("%s", output)
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
    log.event("Generated %s (%.2f MB)", output_path, size / (1024 * 1024))

    return output_path
end

-- Get file size in bytes. wc -c is the only POSIX route that gives a
-- bare integer without parsing differences across BSD/GNU stat.
function SlideshowGenerator.get_file_size(path)
    local handle = io.popen("/usr/bin/wc -c < " .. utils.shell_quoted_arg(path) .. " 2>/dev/null")
    if not handle then return 0 end
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
