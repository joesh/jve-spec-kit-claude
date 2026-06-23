-- Behavior: ui.pulse owns the visibility lifecycle of an in-progress
-- label. attach(opts) takes show(rgba) and hide() callbacks; start()
-- paints the message and pulses its text-color alpha on a cosine curve
-- (PERIOD_S per cycle, A_MIN..A_MAX), stop() takes the message down.
-- Generation guarding prevents stale chained timers from re-painting
-- after stop().
require("test_env")

-- ---------------------------------------------------------------------------
-- Stub the two host globals pulse depends on, BEFORE require'ing the module:
--   qt_monotonic_s             — virtual clock we step manually
--   qt_create_single_shot_timer — captures (delay, cb); never auto-fires
-- ---------------------------------------------------------------------------
local virtual_now = 0
_G.qt_monotonic_s = function() return virtual_now end

local pending = {}  -- queue of {delay_ms=, cb=}
_G.qt_create_single_shot_timer = function(delay_ms, cb)
    pending[#pending + 1] = {delay_ms = delay_ms, cb = cb}
    return {}
end

local function drain_one()
    local entry = table.remove(pending, 1)
    if entry then entry.cb() end
    return entry ~= nil
end

local function clear_pending()
    pending = {}
end

local pulse = require("ui.pulse")

-- ---------------------------------------------------------------------------
-- show/hide capture helpers
-- ---------------------------------------------------------------------------
local events = {}  -- sequence of {"show", rgba} | {"hide"}
local function on_show(rgba) events[#events + 1] = {"show", rgba} end
local function on_hide()     events[#events + 1] = {"hide"} end

local function last_show()
    for i = #events, 1, -1 do
        if events[i][1] == "show" then return events[i][2] end
    end
    return nil
end

local function count(kind)
    local n = 0
    for _, e in ipairs(events) do if e[1] == kind then n = n + 1 end end
    return n
end

local function reset_events() events = {} end

local function parse_alpha(rgba)
    local a = rgba:match("rgba%(%-?%d+,%-?%d+,%-?%d+,([%-%.%d]+)%)")
    assert(a, "unexpected rgba string: " .. tostring(rgba))
    return tonumber(a)
end

local function approx(a, b, tol)
    return math.abs(a - b) <= (tol or 0.005)
end

-- ---------------------------------------------------------------------------
-- TEST 1: start() emits one show frame at A_MIN (cosine phase 0)
-- ---------------------------------------------------------------------------
do
    virtual_now = 100.0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_rgb = {220, 220, 220}})
    p:start()

    assert(count("show") == 1, "start should emit exactly one show; got " .. count("show"))
    assert(count("hide") == 0, "start must not call hide")
    local a0 = parse_alpha(last_show())
    assert(approx(a0, pulse.A_MIN),
        string.format("expected A_MIN=%.3f at t=0, got %.3f", pulse.A_MIN, a0))
    assert(last_show():match("^rgba%(220,220,220,"), "base RGB not preserved: " .. last_show())
end

-- ---------------------------------------------------------------------------
-- TEST 2: half-period → A_MAX; full period → back to A_MIN
-- ---------------------------------------------------------------------------
do
    virtual_now = 0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_rgb = {200, 210, 220}})
    p:start()
    assert(approx(parse_alpha(last_show()), pulse.A_MIN))

    virtual_now = pulse.PERIOD_S * 0.5
    assert(drain_one(), "expected a chained timer to be pending after start")
    assert(approx(parse_alpha(last_show()), pulse.A_MAX),
        string.format("expected A_MAX=%.3f at t=PERIOD/2, got %.3f",
            pulse.A_MAX, parse_alpha(last_show())))

    virtual_now = pulse.PERIOD_S
    assert(drain_one())
    assert(approx(parse_alpha(last_show()), pulse.A_MIN),
        string.format("expected A_MIN=%.3f at t=PERIOD, got %.3f",
            pulse.A_MIN, parse_alpha(last_show())))
end

-- ---------------------------------------------------------------------------
-- TEST 3: stop() calls hide() exactly once and halts the chain
-- ---------------------------------------------------------------------------
do
    virtual_now = 0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_rgb = {220, 220, 220}})
    p:start()
    assert(#pending >= 1, "start should schedule a follow-up tick")
    local shows_before_stop = count("show")

    p:stop()
    assert(count("hide") == 1, "stop should call hide exactly once; got " .. count("hide"))

    -- Drain whatever was queued before stop(). None of them may show or hide.
    while drain_one() do end
    assert(count("show") == shows_before_stop, "stale timer chain showed after stop()")
    assert(count("hide") == 1, "stale timer chain triggered extra hide() calls")
end

-- ---------------------------------------------------------------------------
-- TEST 4: stop() without start() is a no-op (no hide() call)
-- ---------------------------------------------------------------------------
do
    virtual_now = 0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_rgb = {220, 220, 220}})
    p:stop()
    assert(count("hide") == 0, "stop() before start() must not call hide; got " .. count("hide"))
    assert(count("show") == 0)
end

-- ---------------------------------------------------------------------------
-- TEST 5: redundant stop() after a prior stop() is also a no-op
-- ---------------------------------------------------------------------------
do
    virtual_now = 0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_rgb = {220, 220, 220}})
    p:start()
    p:stop()
    assert(count("hide") == 1)
    p:stop()
    assert(count("hide") == 1, "second stop() must not call hide again; got " .. count("hide"))
end

-- ---------------------------------------------------------------------------
-- TEST 6: restart after stop() works (generation counter)
-- ---------------------------------------------------------------------------
do
    virtual_now = 0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_rgb = {220, 220, 220}})
    p:start()
    p:stop()
    reset_events()
    clear_pending()

    p:start()
    assert(count("show") == 1, "restart should emit one show")
    assert(approx(parse_alpha(last_show()), pulse.A_MIN))
end

-- ---------------------------------------------------------------------------
-- TEST 7: double-start is idempotent (no doubled timer chains)
-- ---------------------------------------------------------------------------
do
    virtual_now = 0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_rgb = {220, 220, 220}})
    p:start()
    local pending_after_first = #pending
    local shows_after_first = count("show")
    p:start()
    assert(#pending == pending_after_first,
        string.format("double-start created extra timers: %d → %d", pending_after_first, #pending))
    assert(count("show") == shows_after_first,
        "double-start emitted an extra show")
end

-- ---------------------------------------------------------------------------
-- TEST 8: base_hex parses to expected RGB
-- ---------------------------------------------------------------------------
do
    virtual_now = 0
    clear_pending()
    reset_events()

    local p = pulse.attach({show = on_show, hide = on_hide, base_hex = "#dcdcdc"})
    p:start()
    assert(last_show():match("^rgba%(220,220,220,"), "base_hex not parsed: " .. last_show())
end

print("✅ test_pulse.lua passed")
