-- slideshow_generator.lua
-- Generate MP4 slideshow videos from screenshot sequences using ffmpeg

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

-- Generate slideshow video from screenshot directory
-- @param screenshot_dir: Directory containing screenshot_001.png, screenshot_002.png, etc.
-- @param screenshot_count: Number of screenshots
-- @param output_path: (optional) Output video path, defaults to screenshot_dir/../slideshow.mp4
-- @return: Path to generated video, or nil + error
function SlideshowGenerator.generate(screenshot_dir, screenshot_count, output_path)
    -- Check if ffmpeg is available
    local has_ffmpeg, ffmpeg_info = SlideshowGenerator.check_ffmpeg()
    if not has_ffmpeg then
        return nil, "ffmpeg not available: " .. ffmpeg_info
    end

    -- Check if screenshot directory exists and has files
    if screenshot_count == 0 then
        return nil, "No screenshots to process"
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
        screenshot_dir,
        output_path
    )

    print("[SlideshowGenerator] Running ffmpeg...")
    print("[SlideshowGenerator] Command: " .. cmd)

    -- Execute ffmpeg
    local handle = io.popen(cmd)
    if not handle then
        return nil, "Failed to execute ffmpeg command"
    end

    local output = handle:read("*a")
    local success = handle:close()

    -- Check if ffmpeg succeeded
    if not success then
        print("[SlideshowGenerator] ffmpeg output:")
        print(output)
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
    print(string.format("[SlideshowGenerator] Generated %s (%.2f MB)",
        output_path, size / (1024 * 1024)))

    return output_path
end

-- Get file size in bytes
function SlideshowGenerator.get_file_size(path)
    local handle = io.popen("wc -c < '" .. path .. "' 2>/dev/null")
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
