--- capture_manager.lua
-- Continuous ring buffer capture system for bug reporting
-- Captures gestures, commands, logs, and screenshots in memory
local log = require("core.logger").for_area("ui")
local path_utils = require("core.path_utils")

-- Per-stream caps prevent burst streams (stuck render loop spamming logs,
-- rapid redraws spamming screenshots) from blowing the 10 MB payload
-- cap (FR-024a). Screenshots are bounded by BYTES not COUNT — a single
-- 4K-monitor pixmap is ~33 MB at 32 bpp, so the prior 300-entry cap
-- meant up to 10 GB of RSS (pass 1+2 audit #6 HIGH).
local MAX_GESTURES_IN_BUFFER     = 200
local MAX_COMMANDS_IN_BUFFER     = 200
local MAX_LOGS_IN_BUFFER         = 1000
local MAX_SCREENSHOT_BYTES       = 100 * 1024 * 1024  -- 100 MB hard ceiling
local MAX_CAPTURE_TIME_MINUTES   = 5
local MAX_CAPTURE_TIME_MS = MAX_CAPTURE_TIME_MINUTES * 60 * 1000  -- 5 minutes = 300000ms
local SCREENSHOT_INTERVAL_SECONDS = 1
local SCREENSHOT_INTERVAL_MS = SCREENSHOT_INTERVAL_SECONDS * 1000  -- 1 second = 1000ms

local CaptureManager = {
    -- Configuration
    max_gestures    = MAX_GESTURES_IN_BUFFER,
    max_commands    = MAX_COMMANDS_IN_BUFFER,
    max_logs        = MAX_LOGS_IN_BUFFER,
    max_screenshot_bytes = MAX_SCREENSHOT_BYTES,
    max_time_ms     = MAX_CAPTURE_TIME_MS,
    screenshot_interval_ms = SCREENSHOT_INTERVAL_MS,
    -- Default OFF. telemetry.init flips this to true only after consent
    -- is accepted + /register succeeds (pass 2 #1 HIGH: prior default-on
    -- meant the ring buffer recorded during the consent dialog itself,
    -- with no install_id yet but real user gestures captured).
    capture_enabled = false,
    screenshot_bytes_total = 0,

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

-- One-shot session init. Idempotent: layout.lua's open_project hook
-- calls bug_reporter.init() on every project open, but we MUST NOT
-- wipe the in-session ring buffers mid-life (pass 2 #25). Subsequent
-- calls are no-ops; explicit clear_buffers is the way to drop state.
function CaptureManager:init()
    if self.session_start_time ~= nil then return end
    self.session_start_time = qt_monotonic_s()
    self.gesture_ring_buffer = {}
    self.command_ring_buffer = {}
    self.log_ring_buffer = {}
    self.screenshot_ring_buffer = {}
    self.screenshot_bytes_total = 0
    self.next_gesture_id = 1
    self.next_command_id = 1
    log.event("Capture manager initialized (enabled=%s)", tostring(self.capture_enabled))
end

-- Elapsed milliseconds since session start using monotonic wall time.
function CaptureManager:get_elapsed_ms()
    if not self.session_start_time then
        self.session_start_time = qt_monotonic_s()
    end
    return (qt_monotonic_s() - self.session_start_time) * 1000
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

-- Capture a screenshot. `pixmap` is a QPixmap userdata from the
-- grab_window binding; init.lua's 1 Hz timer is the production caller.
-- Stored entries carry the pixmap reference + its byte cost (queried
-- via qt_pixmap_byte_count). The ring is bounded by total bytes, not
-- count: a single 4K screenshot is ~33 MB at 32 bpp, so a count cap
-- alone meant 300 entries × ~33 MB ≈ 10 GB RSS.
function CaptureManager:capture_screenshot(pixmap)
    if not self.capture_enabled then return end
    if not pixmap then return end  -- grab_window returned nil; nothing to store
    local bytes = qt_pixmap_byte_count(pixmap)
    local entry = {
        timestamp_ms = self:get_elapsed_ms(),
        image        = pixmap,
        bytes        = bytes,
    }
    table.insert(self.screenshot_ring_buffer, entry)
    self.screenshot_bytes_total = self.screenshot_bytes_total + bytes
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

    -- Gestures/commands/logs: bounded by count + wall-age.
    batch_remove(self.gesture_ring_buffer,
        count_removals(self.gesture_ring_buffer, cutoff_time, self.max_gestures))
    batch_remove(self.command_ring_buffer,
        count_removals(self.command_ring_buffer, cutoff_time, self.max_commands))
    batch_remove(self.log_ring_buffer,
        count_removals(self.log_ring_buffer, cutoff_time, self.max_logs))

    -- Screenshots: bounded by total BYTES + wall-age. Evict oldest
    -- entries until both constraints are satisfied. Pixmap memory is
    -- freed by Lua GC once we drop the last reference (QPixmap's __gc
    -- metamethod runs delete on the underlying object).
    while #self.screenshot_ring_buffer > 0 do
        local head = self.screenshot_ring_buffer[1]
        local too_old = head.timestamp_ms < cutoff_time
        local too_big = self.screenshot_bytes_total > self.max_screenshot_bytes
        if not too_old and not too_big then break end
        self.screenshot_bytes_total = self.screenshot_bytes_total - (head.bytes or 0)
        if self.screenshot_bytes_total < 0 then self.screenshot_bytes_total = 0 end
        head.image = nil  -- drop last Lua-side reference; GC frees the QPixmap
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

-- Estimate memory usage in MB. Screenshots use the actual byte-count
-- tracked by capture_screenshot (queried from QPixmap::byte_count);
-- other streams are small enough that per-entry constants suffice.
function CaptureManager:estimate_memory_usage()
    local gesture_mb    = (#self.gesture_ring_buffer * 200) / (1024 * 1024)
    local command_mb    = (#self.command_ring_buffer * 500) / (1024 * 1024)
    local log_mb        = (#self.log_ring_buffer    * 150) / (1024 * 1024)
    local screenshot_mb = self.screenshot_bytes_total      / (1024 * 1024)
    return gesture_mb + command_mb + log_mb + screenshot_mb
end

-- Enable/disable capture (from preferences)
function CaptureManager:set_enabled(enabled)
    self.capture_enabled = enabled
    log.event("Capture %s", enabled and "enabled" or "disabled")
end

function CaptureManager:clear_buffers()
    -- Drop pixmap refs explicitly so GC can free them ASAP rather
    -- than waiting for the new table assignment to drop the old one.
    for _, entry in ipairs(self.screenshot_ring_buffer) do
        entry.image = nil
    end
    self.gesture_ring_buffer = {}
    self.command_ring_buffer = {}
    self.log_ring_buffer = {}
    self.screenshot_ring_buffer = {}
    self.screenshot_bytes_total = 0
    log.event("Buffers cleared")
end

-- Freeze ring buffers + snapshot data + resolve output_dir. Shared
-- prep for sync and async export. Caller is responsible for re-enabling
-- capture (after the sync export returns or in the async callback).
function CaptureManager:_freeze_and_snapshot(metadata)
    local was_enabled = self.capture_enabled
    self.capture_enabled = false
    -- Feature 027 FR-011a: .jvp content MUST NOT ship in any payload.
    local capture_data = {
        gestures    = self.gesture_ring_buffer,
        commands    = self.command_ring_buffer,
        logs        = self.log_ring_buffer,
        screenshots = self.screenshot_ring_buffer,
    }
    metadata.screenshot_interval_ms = self.screenshot_interval_ms
    local output_dir = path_utils.resolve_repo_path(metadata.output_dir or "tests/captures")
    return was_enabled, capture_data, output_dir
end

-- Sync export. Used by capture_on_error (crash path — event loop may
-- be gone, can't wait on QProcess). Blocks for the duration of ffmpeg.
function CaptureManager:export_capture(metadata)
    local json_exporter = require("bug_reporter.json_exporter")
    local was_enabled, capture_data, output_dir = self:_freeze_and_snapshot(metadata)
    local json_path = json_exporter.export(capture_data, metadata, output_dir)
    self.capture_enabled = was_enabled
    log.event("Exported capture to: %s", json_path)
    return json_path
end

-- Async sibling. Used by F12/user-submitted path so the GUI stays
-- responsive while ffmpeg builds slideshow.mp4 (FR-021 — Submit's
-- "Sending…" label updates during the run instead of beachballing).
function CaptureManager:export_capture_async(metadata, on_done)
    assert(type(on_done) == "function", "export_capture_async: on_done required")
    local json_exporter = require("bug_reporter.json_exporter")
    local was_enabled, capture_data, output_dir = self:_freeze_and_snapshot(metadata)
    json_exporter.export_async(capture_data, metadata, output_dir, function(json_path, err)
        self.capture_enabled = was_enabled
        if json_path then
            log.event("Exported capture to: %s", json_path)
        else
            log.error("Async export failed: %s", err or "unknown error")
        end
        on_done(json_path, err)
    end)
end

-- Return module
return CaptureManager
