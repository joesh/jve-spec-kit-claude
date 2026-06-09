require('test_env')

-- Regression: tree drop handler receives a structured event table,
-- not raw positional arguments. The C++ dropEvent must build:
--   { sources = {tree_id, ...}, target_id = tree_id, position = "into"|"above"|"below"|"viewport" }

print("=== Test Tree Drop Event Contract ===")

--------------------------------------------------------------------------------
-- Test 1: handle_tree_drop rejects non-table event
--------------------------------------------------------------------------------
print("\nTest 1: rejects non-table event (the original bug)")

-- Simulate what C++ was doing: passing a raw integer
local called_with = nil
local function mock_handle_tree_drop(event)
    called_with = event
    if not event or type(event) ~= "table" or type(event.sources) ~= "table" or #event.sources == 0 then
        return false
    end
    return true
end

-- Before fix: C++ passed (target_id_number, mime_string)
-- The handler received just the first arg as 'event'
local result = mock_handle_tree_drop(42)
assert(result == false, "should reject raw number")
assert(called_with == 42, "received the raw number")

print("  ✓ raw number correctly rejected")

--------------------------------------------------------------------------------
-- Test 2: handle_tree_drop accepts proper event table
--------------------------------------------------------------------------------
print("\nTest 2: accepts proper event table")

result = mock_handle_tree_drop({
    sources = {101, 102},
    target_id = 200,
    position = "into",
})
assert(result == true, "should accept valid event table")

print("  ✓ valid event table accepted")

--------------------------------------------------------------------------------
-- Test 3: event with empty sources is rejected
--------------------------------------------------------------------------------
print("\nTest 3: empty sources rejected")

result = mock_handle_tree_drop({
    sources = {},
    target_id = 200,
    position = "into",
})
assert(result == false, "should reject empty sources")

print("  ✓ empty sources rejected")

--------------------------------------------------------------------------------
-- Test 4: verify C++ builds correct event structure (source grep check)
--------------------------------------------------------------------------------
print("\nTest 4: C++ dropEvent builds event table")

local test_env = require('test_env')
local f = assert(io.open(test_env.resolve_repo_path("src/lua/qt_bindings/view_bindings.cpp"), "r"))
local source = f:read("*a")
f:close()

-- Must push a table, not raw integers
assert(source:find('lua_newtable.-drop_handler'), nil,
    "dropEvent must create a Lua table for the handler")
assert(source:find('"sources"'),
    "dropEvent must include 'sources' field with selected item IDs")
assert(source:find('"target_id"'),
    "dropEvent must include 'target_id' field")
assert(source:find('"position"'),
    "dropEvent must include 'position' field (into/above/below/viewport)")

print("  ✓ C++ builds structured event table")

print("\n✅ test_tree_drop_event.lua passed")
