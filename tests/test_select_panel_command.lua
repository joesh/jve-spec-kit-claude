require('test_env')

-- Tests for SelectPanel command: focus a named panel
print("=== Test SelectPanel Command ===")

-- Track focus_manager calls
local focused_panel
package.loaded["ui.focus_manager"] = {
    focus_panel = function(panel_id) focused_panel = panel_id end,
    set_focused_panel = function(panel_id) focused_panel = panel_id end,
}

local mod = require("core.commands.select_panel")
local executors = {}
local registered = mod.register(executors, {}, nil)
local executor = registered.executor
assert(type(executor) == "function", "SelectPanel executor should be a function")

local function make_command(positional)
    return {
        get_all_parameters = function() return { _positional = positional } end,
    }
end

-- Test 1: select timeline panel
print("\nTest 1: SelectPanel timeline")
focused_panel = nil
executor(make_command({"timeline"}))
assert(focused_panel == "timeline",
    "Should focus timeline, got: " .. tostring(focused_panel))
print("  ✓ timeline panel focused")

-- Test 2: select inspector panel
print("\nTest 2: SelectPanel inspector")
focused_panel = nil
executor(make_command({"inspector"}))
assert(focused_panel == "inspector",
    "Should focus inspector, got: " .. tostring(focused_panel))
print("  ✓ inspector panel focused")

-- Test 3: select project_browser panel
print("\nTest 3: SelectPanel project_browser")
focused_panel = nil
executor(make_command({"project_browser"}))
assert(focused_panel == "project_browser",
    "Should focus project_browser, got: " .. tostring(focused_panel))
print("  ✓ project_browser panel focused")

-- Test 4: missing panel name asserts
print("\nTest 4: SelectPanel with no panel name asserts")
local ok, err = pcall(executor, make_command({}))
assert(not ok, "SelectPanel with empty positional should assert")
assert(err:match("SelectPanel") and err:match("panel name"),
    "Error should mention SelectPanel and panel name, got: " .. tostring(err))
print("  ✓ asserts on missing panel name")

-- Test 5: nil positional asserts
print("\nTest 5: SelectPanel with nil positional asserts")
local ok2, err2 = pcall(executor, make_command(nil))
assert(not ok2, "SelectPanel with nil positional should assert: " .. tostring(err2))
print("  ✓ asserts on nil positional")

-- Test 6: spec is non-undoable
print("\nTest 6: spec is non-undoable")
assert(registered.spec.undoable == false, "SelectPanel should be non-undoable")
print("  ✓ spec.undoable == false")

print("\n✅ test_select_panel_command.lua passed")
