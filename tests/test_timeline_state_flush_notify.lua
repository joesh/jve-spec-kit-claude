#!/usr/bin/env luajit

-- Regression: interactive viewport mutations must not produce a visible
-- frame-lag between subscribed widgets. The timeline state module
-- coalesces notifications via a debounce timer so bulk drag churn does
-- not cause hundreds of redundant renders. Interactive single events
-- (wheel tick, scrollbar click, ruler scrub, zoom-to-fit) must flush
-- synchronously so every subscriber has observed the new state before
-- control returns to the event loop. Without this guarantee the
-- input-receiving widget repaints on the current frame while every
-- other subscriber lags by the debounce interval, producing a visible
-- stagger during continuous scroll or playhead drag.
--
-- Domain behavior under test (expected values derived from MVC
-- invariants, not from tracing code):
--   * Flushing while idle produces zero extra notifications.
--   * A flush issued between a mutation and the deferred timer must
--     deliver the notification synchronously — subscribers see the new
--     state before the caller regains control.
--   * The deferred timer, which cannot be cancelled from Lua, must
--     become a no-op once the flush has delivered the notification —
--     otherwise every interactive flush produces a ghost second
--     notification one debounce interval later.
--   * After a flush+timer cycle the system must be ready to schedule
--     and deliver a fresh notification cleanly.

require('test_env')

-- Install a controllable timer bridge that captures pending callbacks
-- instead of firing them inline. Must be in place before the state
-- module is required so its internal timer helper observes the bridge.
local pending_timers = {}
_G.qt_create_single_shot_timer = function(_delay_ms, callback)
    table.insert(pending_timers, callback)
    return #pending_timers
end

local function fire_pending_timers()
    local callbacks = pending_timers
    pending_timers = {}
    for _, cb in ipairs(callbacks) do cb() end
end

local data = require('ui.timeline.state.timeline_state_data')

local listener_calls = 0
data.add_listener(function() listener_calls = listener_calls + 1 end)

-- Case 1: flushing while idle is a no-op for subscribers.
local baseline = listener_calls
data.flush_pending_notify()
assert(listener_calls == baseline,
    "idle flush must not invent notifications; delta=" ..
    (listener_calls - baseline))

-- Case 2: mutation schedules a deferred notification; flush delivers it
-- synchronously before the timer fires.
data.notify_listeners()
assert(#pending_timers == 1,
    "mutation must schedule exactly one pending timer; got " .. #pending_timers)
assert(listener_calls == baseline,
    "listener must not fire before flush or timer; delta=" ..
    (listener_calls - baseline))

data.flush_pending_notify()
assert(listener_calls == baseline + 1,
    "flush must deliver notification synchronously; expected +1, got +" ..
    (listener_calls - baseline))

-- Case 3: the deferred timer fires after the flush and must be a no-op.
fire_pending_timers()
assert(listener_calls == baseline + 1,
    "timer fired after flush must be a no-op; expected +1 total, got +" ..
    (listener_calls - baseline))

-- Case 4: the system is ready to schedule and flush a fresh notification.
data.notify_listeners()
assert(#pending_timers == 1,
    "second mutation must schedule a fresh timer; got " .. #pending_timers)
data.flush_pending_notify()
assert(listener_calls == baseline + 2,
    "second flush must deliver exactly one more notification; got +" ..
    (listener_calls - baseline))
fire_pending_timers()
assert(listener_calls == baseline + 2,
    "second stale timer must also be a no-op; got +" ..
    (listener_calls - baseline))

print("✅ test_timeline_state_flush_notify.lua passed")
