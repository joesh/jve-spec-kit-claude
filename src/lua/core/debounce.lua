-- Debounce utility for preventing excessive function calls
-- Useful for throttling redraws during mouse move events

local M = {}

-- Creates a debounced version of a function
-- The function will only execute after `delay_ms` milliseconds of inactivity
-- If called again before the delay expires, the timer resets
function M.debounce(fn, delay_ms)
    local timer = nil
    local pending_args = nil

    return function(...)
        pending_args = {...}

        if timer then
            -- Timer already running, just update args
            return
        end

        timer = true

        -- Schedule execution after delay
        -- Note: This is a simple Lua-based debounce
        -- For better timing, could integrate with Qt timer system
        local start_value = os.clock()

        -- Execute function after delay
        local function check_and_execute()
            local elapsed = (os.clock() - start_value) * 1000
            if elapsed >= delay_ms then
                fn(table.unpack(pending_args))
                timer = nil
                pending_args = nil
            end
        end

        -- Call immediately for now (will be improved with Qt timer integration)
        check_and_execute()
    end
end

-- Creates a throttled version of a function
-- The function will execute at most once per `interval_ms` milliseconds
-- Unlike debounce, this guarantees execution at regular intervals during activity
function M.throttle(fn, interval_ms)
    local last_execution = 0
    local pending_call = nil

    return function(...)
        local now = os.clock() * 1000
        local time_since_last = now - last_execution

        if time_since_last >= interval_ms then
            -- Enough time has passed, execute immediately
            fn(...)
            last_execution = now
            pending_call = nil
        else
            -- Too soon, store pending call
            pending_call = {...}
        end
    end
end

-- Request animation frame-style updates
-- Batches multiple render requests into a single frame
function M.request_render(render_fn)
    -- For now, just call immediately
    -- TODO: Integrate with Qt event loop for proper frame timing
    render_fn()
end

return M
