--- json_exporter.lua
-- Export captured data to JSON test format
local dkjson = require("dkjson")
local utils = require("bug_reporter.utils")
local log = require("core.logger").for_area("ui")
local uuid = require("uuid")
local build_info = require("core.build_info")

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
-- Shared sync prep: validate inputs, mkdir capture/, mkdir screenshots/,
-- dump pixmap ring to PNGs. Returns (capture_dir, screenshot_dir, count)
-- on success; raises on failure (FR-015 fail-fast — partial captures
-- with no on-disk root would otherwise leak ring-buffer references).
local function prepare_capture_dir(capture_data, output_dir)
    assert(capture_data, "json_exporter: capture_data is required")
    local valid, err = utils.validate_non_empty(output_dir, "output_dir")
    assert(valid, err)
    local timestamp = os.time()
    local capture_id = "capture-" .. utils.human_datestamp_for_filename(timestamp) .. "-" .. uuid.generate():sub(1, 8)
    local capture_dir = output_dir .. "/" .. capture_id
    local dir_ok, dir_err = utils.mkdir_p(capture_dir)
    assert(dir_ok, "json_exporter: " .. (dir_err or ("mkdir failed: " .. capture_dir)))
    local screenshot_dir = capture_dir .. "/screenshots"
    local ss_ok, ss_err = utils.mkdir_p(screenshot_dir)
    assert(ss_ok, "json_exporter: " .. (ss_err or ("mkdir failed: " .. screenshot_dir)))
    local count = JsonExporter.export_screenshots(capture_data.screenshots, screenshot_dir)
    return capture_dir, screenshot_dir, count, timestamp, capture_id
end

-- Build + write capture.json. FR-011 + FR-015: rm screenshots/ dir
-- unconditionally before returning so raw PNGs cannot leak into the
-- payload regardless of slideshow success/failure.
local function finalize_capture(capture_dir, screenshot_dir, screenshot_count,
                                slideshow_path, capture_data, metadata,
                                timestamp, capture_id)
    local rm_ok, rm_err = qt_fs_remove_dir_recursive(screenshot_dir)
    assert(rm_ok, "json_exporter: failed to remove " .. screenshot_dir ..
        ": " .. tostring(rm_err))

    local json_data = {
        test_format_version = "1.0",
        test_id = capture_id,
        test_name = metadata.test_name or "Captured bug report",
        category = metadata.category or "unknown",
        tags = metadata.tags or {"capture"},
        capture_metadata = {
            capture_type = metadata.capture_type or "automatic",
            capture_timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp),
            jve_version = metadata.jve_version or build_info.git_sha,
            platform = metadata.platform or JsonExporter.get_platform_info(),
            user_description = metadata.user_description,
            user_expected_behavior = metadata.user_expected_behavior,
            error_message = metadata.error_message,
            lua_stack_trace = metadata.lua_stack_trace
        },
        window_geometry = metadata.window_geometry or {},
        gesture_log = JsonExporter.convert_gesture_log(capture_data.gestures),
        command_log = JsonExporter.convert_command_log(capture_data.commands),
        log_output  = JsonExporter.convert_log_output(capture_data.logs),
        -- Feature 027 FR-011a: .jvp DB content MUST NOT ship; the
        -- legacy database_snapshots/video_recording blocks are dropped.
        screenshots = {
            screenshot_count = screenshot_count,
            screenshot_interval_ms = metadata.screenshot_interval_ms or 1000,
            slideshow_video = slideshow_path,
        },
    }
    local json_path = capture_dir .. "/capture.json"
    local json_str, encode_err = dkjson.encode(json_data, { indent = true })
    assert(json_str, "json_exporter: encode failed: " .. tostring(encode_err))
    local file, open_err = io.open(json_path, "w")
    assert(file, "json_exporter: open failed: " .. tostring(open_err))
    file:write(json_str)
    file:close()
    return json_path
end

function JsonExporter.export(capture_data, metadata, output_dir)
    metadata = metadata or {}
    local capture_dir, screenshot_dir, screenshot_count, timestamp, capture_id
        = prepare_capture_dir(capture_data, output_dir)

    local slideshow_path = nil
    if screenshot_count > 0 then
        local slideshow_generator = require("bug_reporter.slideshow_generator")
        local video_path, gen_err = slideshow_generator.generate(
            screenshot_dir, screenshot_count)
        if video_path then
            slideshow_path = video_path
            log.event("Slideshow video generated: %s", video_path)
        else
            log.warn("Slideshow generation failed: %s", gen_err or "unknown")
        end
    end

    return finalize_capture(capture_dir, screenshot_dir, screenshot_count,
        slideshow_path, capture_data, metadata, timestamp, capture_id)
end

-- Async sibling of export(). Slideshow ffmpeg runs in a background
-- QProcess; everything else is identical (sync). on_done(json_path, err)
-- fires once when the chain completes. Used by F12/user-submitted path
-- to avoid the 10s GUI freeze; crash-capture still uses sync export()
-- because the app may be unwinding and event loop is gone.
function JsonExporter.export_async(capture_data, metadata, output_dir, on_done)
    assert(type(on_done) == "function", "export_async: on_done required")
    metadata = metadata or {}
    local capture_dir, screenshot_dir, screenshot_count, timestamp, capture_id
        = prepare_capture_dir(capture_data, output_dir)

    if screenshot_count == 0 then
        local path = finalize_capture(capture_dir, screenshot_dir, 0, nil,
            capture_data, metadata, timestamp, capture_id)
        on_done(path, nil)
        return
    end

    local slideshow_generator = require("bug_reporter.slideshow_generator")
    slideshow_generator.generate_async(screenshot_dir, screenshot_count, nil,
        function(video_path, gen_err)
            if video_path then
                log.event("Slideshow video generated: %s", video_path)
            else
                log.warn("Slideshow generation failed: %s", gen_err or "unknown")
            end
            local path = finalize_capture(capture_dir, screenshot_dir,
                screenshot_count, video_path, capture_data, metadata,
                timestamp, capture_id)
            on_done(path, nil)
        end)
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
                log.warn("Failed to save screenshot %d", i)
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

-- Convert command ring buffer to JSON format. Parameters + result
-- are redacted via bug_reporter.redact so filesystem paths and
-- $HOME-prefixed strings don't ship to the Worker (FR-019/FR-020).
function JsonExporter.convert_command_log(command_buffer)
    local redact = require("bug_reporter.redact")
    local result = {}
    for _, entry in ipairs(command_buffer) do
        table.insert(result, {
            id = entry.id,
            timestamp_ms = entry.timestamp_ms,
            command = entry.command,
            parameters = redact.redact_parameters(entry.parameters),
            result = redact.redact_parameters(entry.result),
            triggered_by_gesture = entry.triggered_by_gesture,
        })
    end
    return result
end

-- Convert log ring buffer to JSON format. Messages run through
-- redact.redact_string so $HOME-prefixed paths and /Users/<name>/...
-- substrings in log lines (which are user-facing strings, often
-- carrying paths the user touched) don't ship verbatim.
function JsonExporter.convert_log_output(log_buffer)
    local redact = require("bug_reporter.redact")
    local result = {}

    for i, entry in ipairs(log_buffer) do
        table.insert(result, {
            timestamp_ms = entry.timestamp_ms,
            level = entry.level,
            message = redact.redact_string(entry.message)
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
