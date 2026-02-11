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
-- Size: ~221 LOC
-- Volatility: unknown
--
-- @file capture_manager.lua
-- Original intent (unreviewed):
-- capture_manager.lua
-- Continuous ring buffer capture system for bug reporting
-- Captures gestures, commands, logs, and screenshots in memory
local utils = require("bug_reporter.utils")
local logger = require("core.logger")
local path_utils = require("core.path_utils")

-- Configuration constants
local MAX_GESTURES_IN_BUFFER = 200
local MAX_CAPTURE_TIME_MINUTES = 5
local MAX_CAPTURE_TIME_MS = MAX_CAPTURE_TIME_MINUTES * 60 * 1000  -- 5 minutes = 300000ms
local SCREENSHOT_INTERVAL_SECONDS = 1
local SCREENSHOT_INTERVAL_MS = SCREENSHOT_INTERVAL_SECONDS * 1000  -- 1 second = 1000ms

local CaptureManager = {
    -- Configuration
    max_gestures = MAX_GESTURES_IN_BUFFER,
    max_time_ms = MAX_CAPTURE_TIME_MS,
    screenshot_interval_ms = SCREENSHOT_INTERVAL_MS,
    capture_enabled = true,  -- User preference

    -- Ring buffers
    gesture_ring_buffer = {},
    command_ring_buffer = {},
    log_ring_buffer = {},
    screenshot_ring_buffer = {},

    -- State
    session_start_time = nil,
    next_gesture_id = 1,
    next_command_id = 1,
}

-- Initialize capture manager
function CaptureManager:init()
    -- Use os.clock() for monotonic, high-resolution timing (not affected by system clock changes)
    self.session_start_time = os.clock()
    self.gesture_ring_buffer = {}
    self.command_ring_buffer = {}
    self.log_ring_buffer = {}
    self.screenshot_ring_buffer = {}
    self.next_gesture_id = 1
    self.next_command_id = 1

    logger.info("bug_reporter", "Capture manager initialized (enabled=" .. tostring(self.capture_enabled) .. ")")
end

-- Get elapsed milliseconds since session start
-- Uses os.clock() for monotonic, millisecond-precision timing
-- os.clock() is not affected by system clock changes and provides sub-second resolution
function CaptureManager:get_elapsed_ms()
    if not self.session_start_time then
        self.session_start_time = os.clock()
    end
    return (os.clock() - self.session_start_time) * 1000
end

-- Log a gesture event
function CaptureManager:log_gesture(gesture)
    if not self.capture_enabled then
        return
    end

    local entry = {
        id = "g" .. self.next_gesture_id,
        timestamp_ms = self:get_elapsed_ms(),
        gesture = gesture
    }
    self.next_gesture_id = self.next_gesture_id + 1

    table.insert(self.gesture_ring_buffer, entry)
    self:trim_buffers()

    return entry.id
end

-- Log a command execution
function CaptureManager:log_command(command_name, parameters, result, triggered_by_gesture)
    if not self.capture_enabled then
        return
    end

    local entry = {
        id = "c" .. self.next_command_id,
        timestamp_ms = self:get_elapsed_ms(),
        command = command_name,
        parameters = parameters,
        result = result,
        triggered_by_gesture = triggered_by_gesture
    }
    self.next_command_id = self.next_command_id + 1

    table.insert(self.command_ring_buffer, entry)
    self:trim_buffers()

    return entry.id
end

-- Log a message (info, warning, error)
function CaptureManager:log_message(level, message)
    if not self.capture_enabled then
        return
    end

    local entry = {
        timestamp_ms = self:get_elapsed_ms(),
        level = level,
        message = message
    }

    table.insert(self.log_ring_buffer, entry)
    self:trim_buffers()
end

-- Capture a screenshot (stores QPixmap reference in memory)
function CaptureManager:capture_screenshot()
    if not self.capture_enabled then
        return
    end

    -- This will call Qt binding to grab the window
    -- For now, just log that we would capture
    local entry = {
        timestamp_ms = self:get_elapsed_ms(),
        image = nil  -- Will be QPixmap from Qt binding
    }

    table.insert(self.screenshot_ring_buffer, entry)
    self:trim_buffers()
end

-- Trim all ring buffers to stay within limits
-- Optimized to avoid O(n²) by batching removals
function CaptureManager:trim_buffers()
    local current_time = self:get_elapsed_ms()
    local cutoff_time = current_time - self.max_time_ms

    -- Helper: Find number of items to remove from start of buffer
    local function count_removals(buffer, time_cutoff, max_count)
        local count_remove = 0
        local time_remove = 0

        -- Count items exceeding max count
        if max_count and #buffer > max_count then
            count_remove = #buffer - max_count
        end

        -- Count items older than cutoff time
        for i, entry in ipairs(buffer) do
            if entry.timestamp_ms >= time_cutoff then
                break
            end
            time_remove = i
        end

        return math.max(count_remove, time_remove)
    end

    -- Helper: Batch remove items from buffer start
    local function batch_remove(buffer, count, cleanup_fn)
        if count <= 0 then
            return
        end

        -- Call cleanup function on items being removed (if provided)
        if cleanup_fn then
            for i = 1, count do
                if buffer[i] then
                    cleanup_fn(buffer[i])
                end
            end
        end

        -- Create new buffer with remaining items
        local new_buffer = {}
        for i = count + 1, #buffer do
            table.insert(new_buffer, buffer[i])
        end

        -- Replace buffer contents
        for i = 1, #buffer do
            buffer[i] = nil
        end
        for i, entry in ipairs(new_buffer) do
            buffer[i] = entry
        end
    end

    -- Trim gestures by count AND time
    local gesture_remove = count_removals(self.gesture_ring_buffer, cutoff_time, self.max_gestures)
    batch_remove(self.gesture_ring_buffer, gesture_remove)

    -- Trim commands by time only (they're sparse)
    local command_remove = count_removals(self.command_ring_buffer, cutoff_time, nil)
    batch_remove(self.command_ring_buffer, command_remove)

    -- Trim log messages by time only
    local log_remove = count_removals(self.log_ring_buffer, cutoff_time, nil)
    batch_remove(self.log_ring_buffer, log_remove)

    -- Trim screenshots by time only (they're dense at 1/second)
    -- Screenshots contain QPixmap userdata that may need explicit cleanup
    local screenshot_remove = count_removals(self.screenshot_ring_buffer, cutoff_time, nil)
    local function cleanup_screenshot(entry)
        -- Attempt to explicitly clean up QPixmap if delete() method exists
        -- Otherwise rely on Lua GC with __gc metamethod
        if entry.image and type(entry.image.delete) == "function" then
            entry.image:delete()
        end
        entry.image = nil
    end
    batch_remove(self.screenshot_ring_buffer, screenshot_remove, cleanup_screenshot)
end

-- Get buffer statistics (for debugging/preferences display)
function CaptureManager:get_stats()
    local oldest_time = nil
    if #self.gesture_ring_buffer > 0 then
        oldest_time = self.gesture_ring_buffer[1].timestamp_ms
    end

    local age_seconds = 0
    if oldest_time then
        age_seconds = (self:get_elapsed_ms() - oldest_time) / 1000
    end

    return {
        gesture_count = #self.gesture_ring_buffer,
        command_count = #self.command_ring_buffer,
        log_count = #self.log_ring_buffer,
        screenshot_count = #self.screenshot_ring_buffer,
        buffer_age_seconds = age_seconds,
        memory_estimate_mb = self:estimate_memory_usage()
    }
end

-- Estimate memory usage in MB
function CaptureManager:estimate_memory_usage()
    -- Rough estimates:
    -- - Gesture: ~200 bytes each
    -- - Command: ~500 bytes each (includes parameters)
    -- - Log: ~150 bytes each
    -- - Screenshot: ~100KB each (QPixmap in memory, compressed)

    local gesture_mb = (#self.gesture_ring_buffer * 200) / (1024 * 1024)
    local command_mb = (#self.command_ring_buffer * 500) / (1024 * 1024)
    local log_mb = (#self.log_ring_buffer * 150) / (1024 * 1024)
    local screenshot_mb = (#self.screenshot_ring_buffer * 100000) / (1024 * 1024)

    return gesture_mb + command_mb + log_mb + screenshot_mb
end

-- Enable/disable capture (from preferences)
function CaptureManager:set_enabled(enabled)
    self.capture_enabled = enabled
    logger.info("bug_reporter", "Capture " .. (enabled and "enabled" or "disabled"))
end

-- Clear all buffers (for testing or user request)
function CaptureManager:clear_buffers()
    -- Explicitly clean up QPixmap objects in screenshot buffer
    for _, entry in ipairs(self.screenshot_ring_buffer) do
        if entry.image and type(entry.image.delete) == "function" then
            entry.image:delete()
        end
        entry.image = nil
    end

    self.gesture_ring_buffer = {}
    self.command_ring_buffer = {}
    self.log_ring_buffer = {}
    self.screenshot_ring_buffer = {}
    logger.info("bug_reporter", "Buffers cleared")
end

-- Export current capture to disk (Phase 2 implementation)
function CaptureManager:export_capture(metadata)
    local json_exporter = require("bug_reporter.json_exporter")

    -- Freeze capture (stop accepting new entries temporarily)
    local was_enabled = self.capture_enabled
    self.capture_enabled = false

    -- Take database snapshot (if database module available)
    local db_snapshot_path = nil
    if database and database.backup_to_file then
        local suffix = utils.human_datestamp_for_filename(os.time())
        local snapshot_dir = path_utils.resolve_repo_path("tests/captures")
        db_snapshot_path = snapshot_dir .. "/bug-" .. suffix .. ".db"
        local success, err = database.backup_to_file(db_snapshot_path)
        if not success then
            logger.warn("bug_reporter", "Database backup failed: " .. (err or "unknown"))
            db_snapshot_path = nil
        end
    end

    -- Prepare capture data
    local capture_data = {
        gestures = self.gesture_ring_buffer,
        commands = self.command_ring_buffer,
        logs = self.log_ring_buffer,
        screenshots = self.screenshot_ring_buffer
    }

    -- Add capture configuration to metadata
    metadata.database_snapshot_after = db_snapshot_path
    metadata.screenshot_interval_ms = self.screenshot_interval_ms

    -- Set default output directory
    local output_dir = path_utils.resolve_repo_path(metadata.output_dir or "tests/captures")

    -- Export to JSON
    local json_path, err = json_exporter.export(capture_data, metadata, output_dir)

    -- Re-enable capture
    self.capture_enabled = was_enabled

    if not json_path then
        logger.error("bug_reporter", "Export failed: " .. (err or "unknown error"))
        return nil, err
    end

    logger.info("bug_reporter", "Exported capture to: " .. json_path)
    return json_path
end

-- Return module
return CaptureManager
