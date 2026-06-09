-- Tests for core.table_utils: shallow_copy and deep_copy

require("test_env")

local table_utils = require("core.table_utils")

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

print("\n=== table_utils Tests ===")

-- ── shallow_copy ──

-- Returns non-tables as-is
check("shallow_copy(nil) = nil", table_utils.shallow_copy(nil) == nil)
check("shallow_copy(42) = 42", table_utils.shallow_copy(42) == 42)
check("shallow_copy('str') = 'str'", table_utils.shallow_copy("str") == "str")
check("shallow_copy(false) = false", table_utils.shallow_copy(false) == false)

-- Copies flat table
local flat = {a = 1, b = "two", c = true}
local flat_copy = table_utils.shallow_copy(flat)
check("shallow flat: different table", flat_copy ~= flat)
check("shallow flat: a=1", flat_copy.a == 1)
check("shallow flat: b='two'", flat_copy.b == "two")
check("shallow flat: c=true", flat_copy.c == true)

-- Shallow copy shares nested references
local inner = {x = 99}
local nested = {child = inner}
local nested_copy = table_utils.shallow_copy(nested)
check("shallow nested: same inner ref", nested_copy.child == inner)

-- Mutation of original doesn't affect copy (top level)
flat.a = 999
check("shallow: mutation independent", flat_copy.a == 1)

-- Copies array-style tables
local arr = {10, 20, 30}
local arr_copy = table_utils.shallow_copy(arr)
check("shallow array: [1]=10", arr_copy[1] == 10)
check("shallow array: [2]=20", arr_copy[2] == 20)
check("shallow array: [3]=30", arr_copy[3] == 30)
check("shallow array: length=3", #arr_copy == 3)

-- Empty table
local empty_copy = table_utils.shallow_copy({})
check("shallow empty: is table", type(empty_copy) == "table")
check("shallow empty: no keys", next(empty_copy) == nil)

-- ── deep_copy ──

-- Returns non-tables as-is
check("deep_copy(nil) = nil", table_utils.deep_copy(nil) == nil)
check("deep_copy(42) = 42", table_utils.deep_copy(42) == 42)

-- Deep copy creates independent nested tables
local deep_inner = {x = 99}
local deep_nested = {child = deep_inner, val = 7}
local deep_result = table_utils.deep_copy(deep_nested)
check("deep: different outer", deep_result ~= deep_nested)
check("deep: different inner", deep_result.child ~= deep_inner)
check("deep: inner.x=99", deep_result.child.x == 99)
check("deep: val=7", deep_result.val == 7)

-- Mutation of original doesn't affect deep copy
deep_inner.x = 0
check("deep: mutation independent", deep_result.child.x == 99)

-- Deep copy handles multiple nesting levels
local l3 = {v = "leaf"}
local l2 = {next = l3}
local l1 = {next = l2}
local l1_copy = table_utils.deep_copy(l1)
check("deep 3-level: leaf value", l1_copy.next.next.v == "leaf")
check("deep 3-level: all different refs", l1_copy.next ~= l2 and l1_copy.next.next ~= l3)

-- Deep copy handles circular references without infinite loop
local circular = {name = "root"}
circular.self = circular
local circ_copy = table_utils.deep_copy(circular)
check("deep circular: name='root'", circ_copy.name == "root")
check("deep circular: self-ref is copy", circ_copy.self == circ_copy)
check("deep circular: self-ref != original", circ_copy.self ~= circular)

-- Deep copy preserves mixed key types
local mixed = {1, 2, 3, name = "mixed", [true] = "yes"}
local mixed_copy = table_utils.deep_copy(mixed)
check("deep mixed: [1]=1", mixed_copy[1] == 1)
check("deep mixed: name='mixed'", mixed_copy.name == "mixed")
check("deep mixed: [true]='yes'", mixed_copy[true] == "yes")

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_table_utils.lua passed")
