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
-- Size: ~168 LOC
-- Volatility: unknown
--
-- @file json_exporter.lua
-- Original intent (unreviewed):
-- json_exporter.lua
-- Export captured data to JSON test format
local dkjson = require("dkjson")
local utils = require("bug_reporter.utils")
local logger = require("core.logger")
local uuid = require("uuid")

local JsonExporter = {}

--- Export bug reporter capture data to structured JSON test format
-- Creates a timestamped directory containing capture.json with all captured data
-- (gestures, commands, logs, screenshots) plus saved screenshot files and optional
-- slideshow video. The JSON follows the test format schema version 1.0.
--
-- @param capture_data table Required capture data from capture_manager {
--   gestures: array - Ring buffer of user gestures with timestamps,
--   commands: array - Ring buffer of executed commands,
--   logs: array - Ring buffer of log messages,
--   screenshots: array - Ring buffer of QPixmap screenshots
-- }
-- @param metadata table Optional metadata {
--   user_description: string - User's description of the bug,
--   error_message: string - Error message that triggered capture,
--   lua_stack_trace: string - Lua stack trace if available,
--   database_snapshot_after: string - Path to database backup,
--   screenshot_interval_ms: number - Screenshot capture interval
-- }
-- @param output_dir string Required output directory path (e.g., "tests/captures")
-- @return string|nil Success: Path to created capture.json file
-- @return nil, string Failure: nil + error message
-- @usage
--   local path, err = JsonExporter.export(capture_manager_data, {
--     error_message = "Clip split caused crash",
--     user_description = "Splitting clip at 00:01:00 causes immediate crash"
--   }, "tests/captures")
--   if path then
--     print("Exported to: " .. path)
--   end
function JsonExporter.export(capture_data, metadata, output_dir)
    -- Validate parameters
    if not capture_data then
        return nil, "capture_data is required"
    end

    local valid, err = utils.validate_non_empty(output_dir, "output_dir")
    if not valid then
        return nil, err
    end

    metadata = metadata or {}

    -- Create output directory
    local timestamp = os.time()
    local capture_id = "capture-" .. utils.human_datestamp_for_filename(timestamp) .. "-" .. uuid.generate():sub(1, 8)
    local capture_dir = output_dir .. "/" .. capture_id

    local dir_ok, dir_err = utils.mkdir_p(capture_dir)
    if not dir_ok then
        return nil, dir_err or ("Failed to create output directory: " .. capture_dir)
    end

    -- Export screenshots to disk
    local screenshot_dir = capture_dir .. "/screenshots"
    local screenshot_success, screenshot_err = utils.mkdir_p(screenshot_dir)
    if not screenshot_success then
        return nil, screenshot_err or ("Failed to create screenshot directory: " .. screenshot_dir)
    end

    local screenshot_count = JsonExporter.export_screenshots(
        capture_data.screenshots,
        screenshot_dir
    )

    -- Generate slideshow video (Phase 3)
    local slideshow_path = nil
    if screenshot_count > 0 then
        local slideshow_generator = require("bug_reporter.slideshow_generator")
        local video_path, gen_err = slideshow_generator.generate(
            screenshot_dir,
            screenshot_count
        )

        if video_path then
            slideshow_path = video_path
            logger.info("bug_reporter", "Slideshow video generated: " .. video_path)
        else
            logger.warn("bug_reporter", "Slideshow generation failed: " .. (gen_err or "unknown"))
        end
    end

    -- Build JSON structure
    local json_data = {
        test_format_version = "1.0",
        test_id = capture_id,
        test_name = metadata.test_name or "Captured bug report",
        category = metadata.category or "unknown",
        tags = metadata.tags or {"capture"},

        capture_metadata = {
            capture_type = metadata.capture_type or "automatic",
            capture_timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp),
            jve_version = metadata.jve_version or "0.1.0-dev",
            platform = metadata.platform or JsonExporter.get_platform_info(),
            user_description = metadata.user_description,
            user_expected_behavior = metadata.user_expected_behavior,
            error_message = metadata.error_message,
            lua_stack_trace = metadata.lua_stack_trace
        },

        window_geometry = metadata.window_geometry or {},

        gesture_log = JsonExporter.convert_gesture_log(capture_data.gestures),
        command_log = JsonExporter.convert_command_log(capture_data.commands),
        log_output = JsonExporter.convert_log_output(capture_data.logs),

        database_snapshots = {
            before = metadata.database_snapshot_before,
            after = metadata.database_snapshot_after
        },

        screenshots = {
            ring_buffer = screenshot_dir,
            screenshot_count = screenshot_count,
            screenshot_interval_ms = metadata.screenshot_interval_ms or 1000,
            slideshow_video = slideshow_path  -- Phase 3: Now implemented!
        },

        video_recording = {
            youtube_url = nil,  -- Phase 6
            youtube_uploaded = false,
            local_file = nil,
            duration_seconds = 0
        }
    }

    -- Write JSON file
    local json_path = capture_dir .. "/capture.json"
    local json_str, encode_err = dkjson.encode(json_data, { indent = true })
    if not json_str then
        return nil, "Failed to encode JSON: " .. (encode_err or "unknown error")
    end

    local file = io.open(json_path, "w")
    if not file then
        return nil, "Failed to write JSON file: " .. json_path
    end

    file:write(json_str)
    file:close()

    return json_path
end

-- Export screenshots from ring buffer to disk
function JsonExporter.export_screenshots(screenshot_buffer, output_dir)
    local count = 0

    for i, entry in ipairs(screenshot_buffer) do
        if entry.image then
            local filename = string.format("screenshot_%03d.png", i)
            local path = output_dir .. "/" .. filename

            -- Call QPixmap:save() method
            local success = entry.image:save(path)
            if success then
                count = count + 1
            else
                logger.warn("bug_reporter", "Failed to save screenshot " .. i)
            end
        end
    end

    return count
end

-- Convert gesture ring buffer to JSON format
function JsonExporter.convert_gesture_log(gesture_buffer)
    local result = {}

    for i, entry in ipairs(gesture_buffer) do
        table.insert(result, {
            id = entry.id,
            timestamp_ms = entry.timestamp_ms,
            type = entry.gesture.type,
            screen_x = entry.gesture.screen_x,
            screen_y = entry.gesture.screen_y,
            window_x = entry.gesture.window_x,
            window_y = entry.gesture.window_y,
            button = entry.gesture.button,
            key = entry.gesture.key,
            modifiers = entry.gesture.modifiers,
            delta = entry.gesture.delta
        })
    end

    return result
end

-- Convert command ring buffer to JSON format
function JsonExporter.convert_command_log(command_buffer)
    local result = {}

    for i, entry in ipairs(command_buffer) do
        table.insert(result, {
            id = entry.id,
            timestamp_ms = entry.timestamp_ms,
            command = entry.command,
            parameters = entry.parameters,
            result = entry.result,
            triggered_by_gesture = entry.triggered_by_gesture
        })
    end

    return result
end

-- Convert log ring buffer to JSON format
function JsonExporter.convert_log_output(log_buffer)
    local result = {}

    for i, entry in ipairs(log_buffer) do
        table.insert(result, {
            timestamp_ms = entry.timestamp_ms,
            level = entry.level,
            message = entry.message
        })
    end

    return result
end

-- Get platform information
function JsonExporter.get_platform_info()
    local platform = "unknown"

    -- Detect platform from Lua
    if package.config:sub(1,1) == '/' then
        -- Unix-like
        local handle = io.popen("uname -s")
        if handle then
            platform = handle:read("*a"):gsub("\n", "")
            handle:close()
        end
    else
        -- Windows
        platform = "Windows"
    end

    return platform
end

return JsonExporter
