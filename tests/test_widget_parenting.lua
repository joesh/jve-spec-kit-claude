require("test_env")

local error_system = require("core.error_system")

-- widget_parenting requires ui_constants — stub if not available
local ok_uic = pcall(require, "core.ui_constants")
if not ok_uic then
    package.loaded["core.ui_constants"] = {}
end

local widget_parenting = require("core.widget_parenting")

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

print("\n=== Widget Parenting Tests (T23) ===")

-- ============================================================
-- debug_widget_info — smoke test (prints, no return)
-- ============================================================
print("\n--- debug_widget_info ---")
do
    -- Should not crash with various inputs
    local ok1 = pcall(widget_parenting.debug_widget_info, "a_widget", "my_name")
    check("debug_widget_info string widget", ok1)

    local ok2 = pcall(widget_parenting.debug_widget_info, {}, "table_widget")
    check("debug_widget_info table widget", ok2)

    local ok3 = pcall(widget_parenting.debug_widget_info, nil, nil)
    check("debug_widget_info nil args", ok3)

    local ok4 = pcall(widget_parenting.debug_widget_info, 42)
    check("debug_widget_info no name", ok4)
end

-- ============================================================
-- smart_add_child — returns success result
-- ============================================================
print("\n--- smart_add_child ---")
do
    local result = widget_parenting.smart_add_child("parent", "child")
    check("smart_add_child returns table", type(result) == "table")
    check("smart_add_child success", result.success == true)
    check("smart_add_child is_success", error_system.is_success(result))
    check("smart_add_child not error", not error_system.is_error(result))

    -- Works with nil args (stub doesn't validate)
    local result2 = widget_parenting.smart_add_child(nil, nil)
    check("smart_add_child nil args success", result2.success == true)

    -- Works with table args
    local result3 = widget_parenting.smart_add_child({name="parent"}, {name="child"})
    check("smart_add_child table args success", result3.success == true)
end

-- ============================================================
-- Module structure
-- ============================================================
print("\n--- module exports ---")
do
    check("exports debug_widget_info", type(widget_parenting.debug_widget_info) == "function")
    check("exports smart_add_child", type(widget_parenting.smart_add_child) == "function")
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Widget Parenting: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_widget_parenting.lua passed")
