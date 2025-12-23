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
-- Size: ~195 LOC
-- Volatility: unknown
--
-- @file gesture_replay_engine.lua
-- Original intent (unreviewed):
-- gesture_replay_engine.lua
-- Converts gesture log entries back to Qt events for pixel-perfect replay
local GestureReplayEngine = {}

-- Check if Qt bindings are available (will be true when running in JVE)
local has_qt_bindings = type(post_mouse_event) == "function"

-- Convert gesture log entry to Qt event parameters
-- @param gesture_entry: Gesture log entry from JSON test
-- @return: Event type and parameters table for qt_bindings
function GestureReplayEngine.gesture_to_event_params(gesture_entry)
    local gesture = gesture_entry.gesture
    local event_type = nil
    local params = {}

    if gesture.type == "mouse_press" then
        event_type = "QMouseEvent"
        params = {
            event_type = "MouseButtonPress",
            x = gesture.screen_x,
            y = gesture.screen_y,
            button = gesture.button or "left",
            modifiers = gesture.modifiers or {}
        }
    elseif gesture.type == "mouse_release" then
        event_type = "QMouseEvent"
        params = {
            event_type = "MouseButtonRelease",
            x = gesture.screen_x,
            y = gesture.screen_y,
            button = gesture.button or "left",
            modifiers = gesture.modifiers or {}
        }
    elseif gesture.type == "mouse_move" then
        event_type = "QMouseEvent"
        params = {
            event_type = "MouseMove",
            x = gesture.screen_x,
            y = gesture.screen_y,
            buttons = gesture.buttons or {},
            modifiers = gesture.modifiers or {}
        }
    elseif gesture.type == "key_press" then
        event_type = "QKeyEvent"
        params = {
            event_type = "KeyPress",
            key = gesture.key,
            text = gesture.text or "",
            modifiers = gesture.modifiers or {}
        }
    elseif gesture.type == "key_release" then
        event_type = "QKeyEvent"
        params = {
            event_type = "KeyRelease",
            key = gesture.key,
            text = gesture.text or "",
            modifiers = gesture.modifiers or {}
        }
    elseif gesture.type == "wheel" then
        event_type = "QWheelEvent"
        params = {
            event_type = "Wheel",
            x = gesture.screen_x,
            y = gesture.screen_y,
            delta = gesture.delta,
            orientation = gesture.orientation or "vertical",
            modifiers = gesture.modifiers or {}
        }
    else
        return nil, "Unknown gesture type: " .. tostring(gesture.type)
    end

    return event_type, params
end

-- Post a gesture event using Qt bindings
-- @param gesture_entry: Gesture log entry from JSON test
-- @return: Success boolean, error message
function GestureReplayEngine.post_gesture_event(gesture_entry)
    if not has_qt_bindings then
        return false, "Qt bindings not available (not running in JVE)"
    end

    local gesture = gesture_entry.gesture

    if gesture.type == "mouse_press" or gesture.type == "mouse_release" or gesture.type == "mouse_move" then
        local event_type_map = {
            mouse_press = "MouseButtonPress",
            mouse_release = "MouseButtonRelease",
            mouse_move = "MouseMove"
        }

        -- For mouse_move events, pass no button (Qt::NoButton)
        -- For press/release events, use the actual button that was pressed
        local button = "no_button"
        if gesture.type == "mouse_press" or gesture.type == "mouse_release" then
            button = gesture.button or "left"
        end

        -- Use the buttons bitmask from the gesture if available (currently held buttons)
        -- For mouse_move, this represents which buttons are held during the move
        local buttons = gesture.buttons or {}

        local success, err = post_mouse_event(
            event_type_map[gesture.type],
            gesture.screen_x,
            gesture.screen_y,
            button,
            buttons,
            gesture.modifiers or {}
        )
        return success, err
    elseif gesture.type == "key_press" or gesture.type == "key_release" then
        local event_type_map = {
            key_press = "KeyPress",
            key_release = "KeyRelease"
        }

        local success, err = post_key_event(
            event_type_map[gesture.type],
            gesture.key or "",
            gesture.text or "",
            gesture.modifiers or {}
        )
        return success, err
    else
        return false, "Unknown gesture type: " .. tostring(gesture.type)
    end
end

-- Replay a sequence of gestures with timing
-- @param gesture_log: Array of gesture log entries (from JSON test)
-- @param options: Optional parameters (speed_multiplier, max_delay_ms, process_events)
-- @return: Success boolean, error message
function GestureReplayEngine.replay_gestures(gesture_log, options)
    if not has_qt_bindings then
        return false, "Qt bindings not available (not running in JVE)"
    end

    options = options or {}
    local speed_multiplier = options.speed_multiplier or 1.0
    local max_delay_ms = options.max_delay_ms or 5000  -- Cap delays at 5 seconds
    local process_events_enabled = options.process_events ~= false  -- Default true

    if #gesture_log == 0 then
        return true  -- Nothing to replay
    end

    -- First gesture happens immediately
    local success, err = GestureReplayEngine.post_gesture_event(gesture_log[1])
    if not success then
        return false, err
    end

    if process_events_enabled then
        process_events()
    end

    -- Subsequent gestures happen with timing delays
    for i = 2, #gesture_log do
        local prev_timestamp = gesture_log[i - 1].timestamp_ms
        local curr_timestamp = gesture_log[i].timestamp_ms

        local delay_ms = curr_timestamp - prev_timestamp
        delay_ms = delay_ms / speed_multiplier
        delay_ms = math.min(delay_ms, max_delay_ms)

        if delay_ms > 0 then
            sleep_ms(delay_ms)
        end

        local success, err = GestureReplayEngine.post_gesture_event(gesture_log[i])
        if not success then
            return false, err
        end

        if process_events_enabled then
            process_events()
        end
    end

    return true
end

-- Replay gestures in sync with command execution
-- This approach posts gestures and waits for corresponding commands to execute
-- More robust than pure timing-based replay
-- @param gesture_log: Array of gesture entries
-- @param command_log: Array of command entries (for correlation)
-- @param post_event_callback: Function(event_type, params)
-- @param wait_for_command_callback: Function(gesture_id) -> command_entry or nil
-- @return: Success boolean
function GestureReplayEngine.replay_gestures_synchronized(
    gesture_log,
    command_log,
    post_event_callback,
    wait_for_command_callback
)
    -- Build gesture_id -> command map
    local gesture_to_command = {}
    for _, cmd_entry in ipairs(command_log) do
        if cmd_entry.triggered_by_gesture then
            gesture_to_command[cmd_entry.triggered_by_gesture] = cmd_entry
        end
    end

    for i, gesture_entry in ipairs(gesture_log) do
        -- Post gesture event
        local event_type, params = GestureReplayEngine.gesture_to_event_params(gesture_entry)
        if not event_type then
            return false, params
        end
        post_event_callback(event_type, params)

        -- If this gesture triggered a command, wait for that command to execute
        local expected_command = gesture_to_command[gesture_entry.id]
        if expected_command then
            -- Wait for command to execute (via polling or callback)
            local actual_command = wait_for_command_callback(gesture_entry.id)
            if not actual_command then
                return false, "Command did not execute for gesture: " .. gesture_entry.id
            end

            -- Verify command name matches
            if actual_command.command ~= expected_command.command then
                return false, string.format(
                    "Command mismatch: expected '%s', got '%s'",
                    expected_command.command,
                    actual_command.command
                )
            end
        end
    end

    return true
end

-- Calculate timing statistics from gesture log
-- Useful for estimating test duration
-- @param gesture_log: Array of gesture entries
-- @return: Stats table {duration_ms, gesture_count, avg_interval_ms}
function GestureReplayEngine.calculate_timing_stats(gesture_log)
    if #gesture_log == 0 then
        return {duration_ms = 0, gesture_count = 0, avg_interval_ms = 0}
    end

    local first_timestamp = gesture_log[1].timestamp_ms
    local last_timestamp = gesture_log[#gesture_log].timestamp_ms
    local duration_ms = last_timestamp - first_timestamp

    local avg_interval_ms = 0
    if #gesture_log > 1 then
        avg_interval_ms = duration_ms / (#gesture_log - 1)
    end

    return {
        duration_ms = duration_ms,
        gesture_count = #gesture_log,
        avg_interval_ms = avg_interval_ms
    }
end

return GestureReplayEngine
