require("test_env")

local selection_hub = require("ui.selection_hub")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

local function fresh()
    selection_hub._reset_for_tests()
end

print("\n=== Selection Hub Tests (T17) ===")

-- ============================================================
-- get_active_selection — no active panel
-- ============================================================
print("\n--- initial state ---")
do
    fresh()
    local items, panel = selection_hub.get_active_selection()
    check("initial items empty", #items == 0)
    check("initial panel nil", panel == nil)
end

-- ============================================================
-- update_selection + get_selection
-- ============================================================
print("\n--- update_selection ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip_a", "clip_b"})
    local items = selection_hub.get_selection("timeline")
    check("timeline has 2 items", #items == 2)
    check("item[1]", items[1] == "clip_a")
    check("item[2]", items[2] == "clip_b")

    -- Different panel
    selection_hub.update_selection("browser", {"media_1"})
    local b_items = selection_hub.get_selection("browser")
    check("browser has 1 item", #b_items == 1)

    -- Timeline unaffected
    local t_items = selection_hub.get_selection("timeline")
    check("timeline still 2", #t_items == 2)

    -- Nonexistent panel
    local none = selection_hub.get_selection("viewer")
    check("viewer empty", #none == 0)
end

-- ============================================================
-- update_selection — nil panel no-op
-- ============================================================
print("\n--- update nil panel ---")
do
    fresh()
    selection_hub.update_selection(nil, {"stuff"})
    -- Should not crash, no effect
    check("nil panel no-op", true)
end

-- ============================================================
-- update_selection — nil items → empty
-- ============================================================
print("\n--- update nil items ---")
do
    fresh()
    selection_hub.update_selection("p1", nil)
    local items = selection_hub.get_selection("p1")
    check("nil items → empty table", #items == 0)
end

-- ============================================================
-- clear_selection
-- ============================================================
print("\n--- clear_selection ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip_a"})
    selection_hub.clear_selection("timeline")
    local items = selection_hub.get_selection("timeline")
    check("cleared → empty", #items == 0)

    -- nil panel no-op
    selection_hub.clear_selection(nil)
    check("clear nil panel no-op", true)
end

-- ============================================================
-- set_active_panel + get_active_selection
-- ============================================================
print("\n--- set_active_panel ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip_x"})
    selection_hub.update_selection("browser", {"media_y"})

    selection_hub.set_active_panel("timeline")
    local items, panel = selection_hub.get_active_selection()
    check("active = timeline", panel == "timeline")
    check("active items = timeline's", #items == 1 and items[1] == "clip_x")

    selection_hub.set_active_panel("browser")
    local items2, panel2 = selection_hub.get_active_selection()
    check("switched to browser", panel2 == "browser")
    check("browser items", #items2 == 1 and items2[1] == "media_y")
end

-- ============================================================
-- listeners — registration and notification
-- ============================================================
print("\n--- listeners ---")
do
    fresh()
    local received_items = nil
    local received_panel = nil
    local call_count = 0

    local token = selection_hub.register_listener(function(items, panel_id)
        received_items = items
        received_panel = panel_id
        call_count = call_count + 1
    end)

    check("register returns token", type(token) == "number")
    -- Listener called immediately on registration with current state
    check("immediate callback on register", call_count == 1)
    check("initial items empty", received_items and #received_items == 0)
end

-- ============================================================
-- listeners — notified on active panel update
-- ============================================================
print("\n--- listener notification ---")
do
    fresh()
    local notifications = {}

    selection_hub.register_listener(function(items, panel_id)
        table.insert(notifications, {items = items, panel = panel_id})
    end)

    -- 1st notification: immediate on register
    check("1 notification after register", #notifications == 1)

    -- Set active panel
    selection_hub.set_active_panel("timeline")
    check("2 notifications after set_active_panel", #notifications == 2)
    check("notified with timeline", notifications[2].panel == "timeline")

    -- Update active panel's selection
    selection_hub.update_selection("timeline", {"new_clip"})
    check("3 notifications after update", #notifications == 3)
    check("notified with items", #notifications[3].items == 1)
    check("item = new_clip", notifications[3].items[1] == "new_clip")
end

-- ============================================================
-- listeners — NOT notified on inactive panel update
-- ============================================================
print("\n--- inactive panel no notify ---")
do
    fresh()
    local call_count = 0

    selection_hub.set_active_panel("timeline")
    selection_hub.register_listener(function()
        call_count = call_count + 1
    end)

    local before = call_count
    selection_hub.update_selection("browser", {"ignored"})
    check("inactive update no notify", call_count == before)

    selection_hub.clear_selection("browser")
    check("inactive clear no notify", call_count == before)
end

-- ============================================================
-- listeners — error isolation
-- ============================================================
print("\n--- listener error isolation ---")
do
    fresh()
    selection_hub.set_active_panel("timeline")

    local good_called = false
    local should_crash = false

    -- Register a listener that only crashes after we enable it (avoid crash during registration callback)
    selection_hub.register_listener(function()
        if should_crash then error("listener crash") end
    end)
    selection_hub.register_listener(function() good_called = true end)

    -- Now enable crash and trigger notification
    should_crash = true
    selection_hub.update_selection("timeline", {"test"})
    check("good listener called despite crash", good_called)
end

-- ============================================================
-- unregister_listener
-- ============================================================
print("\n--- unregister ---")
do
    fresh()
    selection_hub.set_active_panel("timeline")

    local call_count = 0
    local token = selection_hub.register_listener(function()
        call_count = call_count + 1
    end)

    local before = call_count
    selection_hub.update_selection("timeline", {"a"})
    check("listener called before unregister", call_count > before)

    selection_hub.unregister_listener(token)
    local after_unreg = call_count
    selection_hub.update_selection("timeline", {"b"})
    check("listener NOT called after unregister", call_count == after_unreg)
end

-- ============================================================
-- register_listener — non-function error
-- ============================================================
print("\n--- register non-function ---")
do
    fresh()
    expect_error("string callback", function()
        selection_hub.register_listener("not_a_function")
    end, "requires a callback function")

    expect_error("nil callback", function()
        selection_hub.register_listener(nil)
    end, "requires a callback function")
end

-- ============================================================
-- multiple listeners
-- ============================================================
print("\n--- multiple listeners ---")
do
    fresh()
    selection_hub.set_active_panel("panel")

    local results = {}
    selection_hub.register_listener(function(items) table.insert(results, "A") end)
    selection_hub.register_listener(function(items) table.insert(results, "B") end)

    -- Clear initial registration calls
    local initial = #results
    selection_hub.update_selection("panel", {"x"})
    check("both listeners called", #results == initial + 2)
end

-- ============================================================
-- set_active_panel — nil
-- ============================================================
print("\n--- set_active_panel nil ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip"})
    selection_hub.set_active_panel("timeline")
    selection_hub.set_active_panel(nil)

    local items, panel = selection_hub.get_active_selection()
    check("nil active panel", panel == nil)
    check("nil panel → empty items", #items == 0)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Selection Hub: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_selection_hub.lua passed")
