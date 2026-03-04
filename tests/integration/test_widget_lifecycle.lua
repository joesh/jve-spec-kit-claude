--- Integration test: widget lifecycle tracking
-- Verifies that destroyed Qt objects are detected by lua_to_widget
-- (returns nil/error instead of dangling pointer → segfault).

print("=== test_widget_lifecycle ===")

-- Verify we have the required Qt bindings
assert(type(qt_constants) == "table", "must run via JVEEditor --test")
assert(type(qt_constants.WIDGET) == "table", "WIDGET bindings required")
assert(type(qt_constants.CONTROL) == "table", "CONTROL bindings required")
assert(type(qt_create_single_shot_timer) == "function", "qt_create_single_shot_timer required")

-- Helper: pump Qt event loop
local function pump(ms)
    ms = ms or 100
    local start = os.clock()
    local target = start + (ms / 1000.0)
    while os.clock() < target do
        qt_constants.CONTROL.PROCESS_EVENTS()
    end
end

local passed = 0
local total = 0
local function check(desc, condition)
    total = total + 1
    assert(condition, "FAIL: " .. desc)
    passed = passed + 1
    print("  PASS: " .. desc)
end

--------------------------------------------------------------------------------
-- Test 1: Live widget works normally
--------------------------------------------------------------------------------
print("\n-- 1. Live widget accepts operations --")

local button = qt_constants.WIDGET.CREATE_BUTTON("Test Lifecycle")
check("button created", button ~= nil)

local ok, _ = pcall(function()
    qt_set_widget_stylesheet(button, "color: red;")
end)
check("live widget accepts stylesheet", ok)

--------------------------------------------------------------------------------
-- Test 2: Destroyed QTimer detected as dead
-- QTimer fires → deleteLater() → event loop processes → QObject destroyed
-- → QPointer auto-nulls → lua_to_widget returns nil
--------------------------------------------------------------------------------
print("\n-- 2. Destroyed QTimer lifecycle --")

local timer_callback_fired = false
local timer_ref = qt_create_single_shot_timer(1, function()
    timer_callback_fired = true
end)
check("timer created", timer_ref ~= nil)

-- Pump events: timer fires (1ms) → deleteLater() → next iteration destroys it
pump(200)
check("timer callback fired", timer_callback_fired)

-- Now try to use the dead timer — should produce error, NOT segfault
local ok2, err2 = pcall(function()
    qt_set_widget_stylesheet(timer_ref, "color: red;")
end)
check("dead widget produces error (not crash)", not ok2)
check("error mentions widget required",
    type(err2) == "string" and err2:find("widget required") ~= nil)

--------------------------------------------------------------------------------
-- Test 3: Second call on same dead ref also safe (userdata was nulled)
--------------------------------------------------------------------------------
print("\n-- 3. Repeated access to dead widget --")

local ok3, err3 = pcall(function()
    qt_set_widget_stylesheet(timer_ref, "background: blue;")
end)
check("second call on dead widget also errors", not ok3)
check("second error also mentions widget required",
    type(err3) == "string" and err3:find("widget required") ~= nil)

--------------------------------------------------------------------------------
-- Test 4: Multiple timers — each independently tracked
--------------------------------------------------------------------------------
print("\n-- 4. Multiple independent timers --")

local count = 0
local refs = {}
for i = 1, 3 do
    refs[i] = qt_create_single_shot_timer(1, function()
        count = count + 1
    end)
    check("timer " .. i .. " created", refs[i] ~= nil)
end

pump(200)
check("all 3 timer callbacks fired", count == 3)

for i = 1, 3 do
    local ok_i, _ = pcall(function()
        qt_set_widget_stylesheet(refs[i], "color: red;")
    end)
    check("dead timer " .. i .. " produces error", not ok_i)
end

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------
print(string.format("\n=== Results: %d/%d passed ===", passed, total))
print("✅ test_widget_lifecycle.lua passed")
