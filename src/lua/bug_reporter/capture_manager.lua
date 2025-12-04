-- capture_manager.lua
-- Continuous ring buffer capture system for bug reporting
-- Captures gestures, commands, logs, and screenshots in memory

local CaptureManager = {
    -- Configuration
    max_gestures = 200,
    max_time_ms = 300000,  -- 5 minutes
    screenshot_interval_ms = 1000,  -- 1 second
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
    self.session_start_time = os.clock()
    self.gesture_ring_buffer = {}
    self.command_ring_buffer = {}
    self.log_ring_buffer = {}
    self.screenshot_ring_buffer = {}
    self.next_gesture_id = 1
    self.next_command_id = 1

    print("[CaptureManager] Initialized (capture_enabled=" .. tostring(self.capture_enabled) .. ")")
end

-- Get elapsed milliseconds since session start
function CaptureManager:get_elapsed_ms()
    if not self.session_start_time then
        self.session_start_time = os.clock()
    end
    return math.floor((os.clock() - self.session_start_time) * 1000)
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
function CaptureManager:trim_buffers()
    local current_time = self:get_elapsed_ms()
    local cutoff_time = current_time - self.max_time_ms

    -- Trim gestures by count AND time
    while #self.gesture_ring_buffer > self.max_gestures do
        table.remove(self.gesture_ring_buffer, 1)
    end
    while #self.gesture_ring_buffer > 0 and
          self.gesture_ring_buffer[1].timestamp_ms < cutoff_time do
        table.remove(self.gesture_ring_buffer, 1)
    end

    -- Trim commands by time only (they're sparse)
    while #self.command_ring_buffer > 0 and
          self.command_ring_buffer[1].timestamp_ms < cutoff_time do
        table.remove(self.command_ring_buffer, 1)
    end

    -- Trim log messages by time only
    while #self.log_ring_buffer > 0 and
          self.log_ring_buffer[1].timestamp_ms < cutoff_time do
        table.remove(self.log_ring_buffer, 1)
    end

    -- Trim screenshots by time only (they're dense at 1/second)
    while #self.screenshot_ring_buffer > 0 and
          self.screenshot_ring_buffer[1].timestamp_ms < cutoff_time do
        table.remove(self.screenshot_ring_buffer, 1)
    end
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
    print("[CaptureManager] Capture " .. (enabled and "enabled" or "disabled"))
end

-- Clear all buffers (for testing or user request)
function CaptureManager:clear_buffers()
    self.gesture_ring_buffer = {}
    self.command_ring_buffer = {}
    self.log_ring_buffer = {}
    self.screenshot_ring_buffer = {}
    print("[CaptureManager] Buffers cleared")
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
        db_snapshot_path = "tests/captures/bug-" .. os.time() .. ".db"
        local success, err = database.backup_to_file(db_snapshot_path)
        if not success then
            print("[CaptureManager] Warning: Database backup failed: " .. (err or "unknown"))
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

    -- Add database snapshot to metadata
    metadata.database_snapshot_after = db_snapshot_path

    -- Set default output directory
    local output_dir = metadata.output_dir or "tests/captures"

    -- Export to JSON
    local json_path, err = json_exporter.export(capture_data, metadata, output_dir)

    -- Re-enable capture
    self.capture_enabled = was_enabled

    if not json_path then
        print("[CaptureManager] Export failed: " .. (err or "unknown error"))
        return nil, err
    end

    print("[CaptureManager] Exported capture to: " .. json_path)
    return json_path
end

-- Return module
return CaptureManager
