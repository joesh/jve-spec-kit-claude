--- init.lua
-- Bug reporter initialization and Qt bindings integration
local capture_manager = require("bug_reporter.capture_manager")
local log = require("core.logger").for_area("ui")

local BugReporter = {
    screenshot_timer = nil,
    gesture_logger_installed = false
}

-- Initialize the bug reporter system. Idempotent — safe to call from
-- every project_open. Creates the timer + installs the gesture logger
-- but leaves capture DISABLED. telemetry.init flips capture_enabled
-- after consent is verified; capture pipeline ONLY records once that
-- happens (pass 2 #1 HIGH).
function BugReporter.init()
    capture_manager:init()
    BugReporter.install_gesture_logger()
    BugReporter.create_screenshot_timer()
    log.event("Bug reporter initialized (capture gated on telemetry consent)")
end

-- Install gesture logger with callback to capture_manager
function BugReporter.install_gesture_logger()
    if BugReporter.gesture_logger_installed then
        return
    end

    -- Check if Qt binding is available
    if not install_gesture_logger then
        log.warn("install_gesture_logger not available (Qt bindings not loaded)")
        return
    end

    -- Install with callback to capture_manager
    install_gesture_logger(function(gesture)
        capture_manager:log_gesture(gesture)
    end)

    BugReporter.gesture_logger_installed = true
    log.event("Gesture logger installed")
end

-- Create the 1-Hz screenshot timer but DO NOT start it. set_enabled(true)
-- starts it once telemetry has verified consent + register.
function BugReporter.create_screenshot_timer()
    if BugReporter.screenshot_timer then return end
    if not create_timer then
        log.warn("create_timer not available (Qt bindings not loaded)")
        return
    end
    BugReporter.screenshot_timer = create_timer(
        1000,
        true,
        function() BugReporter.capture_screenshot() end
    )
    assert(BugReporter.screenshot_timer,
        "BugReporter: create_timer returned nil despite binding being present")
    log.event("Screenshot timer created (idle until telemetry enables it)")
end

-- Capture a screenshot
function BugReporter.capture_screenshot()
    -- Check if Qt binding is available
    if not grab_window then
        -- Silently skip if binding not available
        return
    end

    -- Skip during transport playback. QWidget::grab() on the JVE main
    -- window walks the entire widget tree (timeline view + Metal video
    -- surface readback) on the GUI thread and stalls it ~300-400 ms;
    -- at this timer's 1 Hz cadence that's a steady, exactly-periodic
    -- video judder under play. Gestures + logs still capture during
    -- playback (the gesture logger isn't tied to this path); only the
    -- visual frame in the ring buffer is paused while playing.
    --
    -- record_engine may be nil before a project is open (transport
    -- itself loads at startup; the engine is bound on open_project).
    -- Nil engine = nothing playing → proceed to capture.
    local transport = require("core.playback.transport")
    local engine = transport.record_engine
    if engine and engine:is_playing() then
        return  -- 1 Hz log line dropped per T010b; play-skip is the only quiet behavior worth its own line.
    end

    local pixmap = grab_window()
    if pixmap then
        capture_manager:capture_screenshot(pixmap)
    end
end

-- (capture_manager:capture_screenshot(pixmap) lives on the class —
-- previously this module monkey-patched a replacement here, which made
-- ownership of the screenshot pipeline ambiguous and bypassed the
-- class's byte-bound ring trimming.)

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

    log.event(enabled and "Enabled" or "Disabled")
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

    local json_path, err = BugReporter.export_capture(metadata)

    if json_path then
        log.event("\n%s", string.rep("=", 60))
        log.event("BUG CAPTURED")
        log.event("%s", string.rep("=", 60))
        log.error("Error: %s", error_message or "unknown")
        log.event("Capture saved to: %s", json_path)
        log.event("\nThis capture includes:")
        log.event("  - Last 5 minutes of gestures and commands")
        log.event("  - Screenshots from the session")
        log.event("  - Full error stack trace")
        log.event("%s\n", string.rep("=", 60))
    else
        log.error("Auto capture failed: %s", err or "unknown error")
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

    local json_path, err = BugReporter.export_capture(metadata)

    if json_path then
        log.event("Manual capture saved to: %s", json_path)
    else
        log.error("Manual capture failed: %s", err or "unknown error")
    end

    return json_path
end

return BugReporter
