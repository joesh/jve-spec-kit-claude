-- init.lua
-- Bug reporter initialization and Qt bindings integration

local capture_manager = require("bug_reporter.capture_manager")
local logger = require("core.logger")

local BugReporter = {
    screenshot_timer = nil,
    gesture_logger_installed = false
}

-- Initialize the bug reporter system
function BugReporter.init()
    -- Initialize capture manager
    capture_manager:init()

    -- Install gesture logger
    BugReporter.install_gesture_logger()

    -- Start screenshot timer
    BugReporter.start_screenshot_timer()

    logger.info("bug_reporter", "Initialized successfully")
end

-- Install gesture logger with callback to capture_manager
function BugReporter.install_gesture_logger()
    if BugReporter.gesture_logger_installed then
        return
    end

    -- Check if Qt binding is available
    if not install_gesture_logger then
        logger.warn("bug_reporter", "install_gesture_logger not available (Qt bindings not loaded)")
        return
    end

    -- Install with callback to capture_manager
    install_gesture_logger(function(gesture)
        capture_manager:log_gesture(gesture)
    end)

    BugReporter.gesture_logger_installed = true
    logger.info("bug_reporter", "Gesture logger installed")
end

-- Start screenshot timer (captures every 1 second)
function BugReporter.start_screenshot_timer()
    -- If timer already running, don't create another
    if BugReporter.screenshot_timer then
        return
    end

    -- Check if Qt binding is available
    if not create_timer then
        logger.warn("bug_reporter", "create_timer not available (Qt bindings not loaded)")
        return
    end

    -- Create timer with callback to capture screenshot
    BugReporter.screenshot_timer = create_timer(
        1000,  -- 1 second interval
        true,  -- repeat mode
        function()
            BugReporter.capture_screenshot()
        end
    )

    -- Check if timer creation succeeded
    if not BugReporter.screenshot_timer then
        logger.error("bug_reporter", "Failed to create screenshot timer")
        return
    end

    BugReporter.screenshot_timer:start()
    logger.info("bug_reporter", "Screenshot timer started (1 second interval)")
end

-- Capture a screenshot
function BugReporter.capture_screenshot()
    -- Check if Qt binding is available
    if not grab_window then
        -- Silently skip if binding not available
        return
    end

    local pixmap = grab_window()
    if pixmap then
        capture_manager:capture_screenshot(pixmap)
    end
end

-- Update capture_manager to store QPixmap
local original_capture_screenshot = capture_manager.capture_screenshot
function capture_manager:capture_screenshot(pixmap)
    if not self.capture_enabled then
        return
    end

    local entry = {
        timestamp_ms = self:get_elapsed_ms(),
        image = pixmap  -- QPixmap userdata from Qt
    }

    table.insert(self.screenshot_ring_buffer, entry)
    self:trim_buffers()
end

-- Enable/disable entire bug reporter system
function BugReporter.set_enabled(enabled)
    capture_manager:set_enabled(enabled)

    -- Also enable/disable gesture logger
    if set_gesture_logger_enabled then
        set_gesture_logger_enabled(enabled)
    end

    -- Start/stop screenshot timer
    if BugReporter.screenshot_timer then
        if enabled then
            BugReporter.screenshot_timer:start()
        else
            BugReporter.screenshot_timer:stop()
        end
    end

    logger.info("bug_reporter", enabled and "Enabled" or "Disabled")
end

-- Get statistics (delegates to capture_manager)
function BugReporter.get_stats()
    return capture_manager:get_stats()
end

-- Export capture to disk (Phase 2 - now implemented!)
function BugReporter.export_capture(metadata)
    metadata = metadata or {}
    return capture_manager:export_capture(metadata)
end

-- Capture bug on error (automatic)
function BugReporter.capture_on_error(error_message, stack_trace)
    local metadata = {
        capture_type = "automatic",
        test_name = "Automatic capture: " .. (error_message or "Unknown error"),
        category = "error",
        tags = {"automatic", "error"},
        error_message = error_message,
        lua_stack_trace = stack_trace
    }

    local json_path = BugReporter.export_capture(metadata)

    if json_path then
        logger.info("bug_reporter", "\n" .. string.rep("=", 60))
        logger.info("bug_reporter", "BUG CAPTURED")
        logger.info("bug_reporter", string.rep("=", 60))
        logger.error("bug_reporter", "Error: " .. (error_message or "unknown"))
        logger.info("bug_reporter", "Capture saved to: " .. json_path)
        logger.info("bug_reporter", "\nThis capture includes:")
        logger.info("bug_reporter", "  - Last 5 minutes of gestures and commands")
        logger.info("bug_reporter", "  - Screenshots from the session")
        logger.info("bug_reporter", "  - Full error stack trace")
        logger.info("bug_reporter", string.rep("=", 60) .. "\n")
    end

    return json_path
end

-- Manual bug capture (user-initiated)
function BugReporter.capture_manual(description, expected_behavior)
    local metadata = {
        capture_type = "user_submitted",
        test_name = description or "User-submitted bug report",
        category = "user_report",
        tags = {"user_submitted", "manual"},
        user_description = description,
        user_expected_behavior = expected_behavior
    }

    local json_path = BugReporter.export_capture(metadata)

    if json_path then
        logger.info("bug_reporter", "Manual capture saved to: " .. json_path)
    end

    return json_path
end

return BugReporter
