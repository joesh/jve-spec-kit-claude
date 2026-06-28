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

    local pixmap, main_widget = grab_window()
    if pixmap then
        -- FR-020a: pixel-side redaction lives in Lua (Rule 2.18).
        -- main_widget is the ancestor coord system; grab_window pushed
        -- it as the 2nd return so the policy doesn't need a separate
        -- main-window lookup binding.
        require("bug_reporter.pixmap_redact").apply(pixmap, main_widget)
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

-- Capture bug on error (automatic). The editor is already unwinding
-- when this fires — a hard-assert inside the export pipeline would
-- bury the original error under a secondary bug-reporter crash, so
-- we pcall the export and route any failure to log.error. Interactive
-- callers (capture_manual) keep fail-fast semantics; only the crash
-- path is soft.
function BugReporter.capture_on_error(error_message, stack_trace)
    local metadata = {
        capture_type = "automatic",
        test_name = "Automatic capture: " .. (error_message or "Unknown error"),
        category = "error",
        tags = {"automatic", "error"},
        error_message = error_message,
        lua_stack_trace = stack_trace
    }

    local ok, json_path_or_err = pcall(BugReporter.export_capture, metadata)

    if ok and json_path_or_err then
        local json_path = json_path_or_err
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
        return json_path
    end

    log.error("Auto capture failed during crash unwind: %s",
        tostring(json_path_or_err))
    return nil
end

local function manual_metadata(description, expected_behavior)
    return {
        capture_type = "user_submitted",
        test_name = description or "User-submitted bug report",
        category = "user_report",
        tags = {"user_submitted", "manual"},
        user_description = description,
        user_expected_behavior = expected_behavior,
    }
end

-- Manual bug capture (sync). Kept for callers that cannot wait on the
-- Qt event loop. F12/user-submitted path uses capture_manual_async.
function BugReporter.capture_manual(description, expected_behavior)
    local json_path = BugReporter.export_capture(manual_metadata(description, expected_behavior))
    log.event("Manual capture saved to: %s", json_path)
    return json_path
end

-- Async sibling. Fires on_done(json_path, err) once the slideshow
-- QProcess finishes. Returns immediately; the F12 dialog updates its
-- status_label between Submit-click and on_done firing.
function BugReporter.capture_manual_async(description, expected_behavior, on_done)
    assert(type(on_done) == "function", "capture_manual_async: on_done required")
    capture_manager:export_capture_async(
        manual_metadata(description, expected_behavior),
        function(json_path, err)
            if json_path then
                log.event("Manual capture saved to: %s", json_path)
            else
                log.error("Manual capture failed: %s", err or "unknown error")
            end
            on_done(json_path, err)
        end)
end

return BugReporter
