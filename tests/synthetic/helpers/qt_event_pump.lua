--- Wall-clock Qt event-loop pump helpers.
--
-- Any test that drives Qt event-loop progress (timers firing,
-- deleteLater draining, deferred callbacks, predicate-on-Qt-state
-- polling) waits in wall clock, not CPU time. Policy: see comment at
-- src/qt_bindings.cpp:331 — os.clock() is cumulative CPU across
-- threads and skews arbitrarily vs wall under parallel-test
-- contention, racing Qt's wall-clock event loop.
--
-- This module is the single canonical source for that pattern; the
-- prior duplication across test_widget_lifecycle, test_inspector_focus_scroll,
-- test_lua_callback_stack_trace, and ui_test_env.M.pump collapses here.
--
-- Requires JVE's --test mode (qt_monotonic_s + qt_constants).

local M = {}

assert(type(qt_monotonic_s) == "function",
    "qt_event_pump: qt_monotonic_s binding required (run via --test)")
assert(type(qt_constants) == "table" and type(qt_constants.CONTROL) == "table",
    "qt_event_pump: qt_constants.CONTROL not available (run via --test)")

--- Pump Qt events for at least `ms` milliseconds wall clock.
function M.pump(ms)
    assert(type(ms) == "number" and ms >= 0,
        "qt_event_pump.pump: ms must be a non-negative number")
    local target = qt_monotonic_s() + (ms / 1000.0)
    while qt_monotonic_s() < target do
        qt_constants.CONTROL.PROCESS_EVENTS()
    end
end

--- Pump Qt events until `predicate()` returns truthy, or `timeout_ms`
-- wall-clock milliseconds elapse. Returns whether predicate was met
-- before the deadline.
function M.pump_until(predicate, timeout_ms)
    assert(type(predicate) == "function",
        "qt_event_pump.pump_until: predicate must be a function")
    assert(type(timeout_ms) == "number" and timeout_ms >= 0,
        "qt_event_pump.pump_until: timeout_ms must be a non-negative number")
    local deadline = qt_monotonic_s() + (timeout_ms / 1000.0)
    while qt_monotonic_s() < deadline do
        qt_constants.CONTROL.PROCESS_EVENTS()
        if predicate() then return true end
    end
    return false
end

return M
