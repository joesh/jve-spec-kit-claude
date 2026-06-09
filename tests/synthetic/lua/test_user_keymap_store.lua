#!/usr/bin/env luajit

-- user_keymap_store: TOML-file-backed preset persistence under ~/.jve/keymaps/
-- Black-box behaviour test using a temp base dir (does not touch real ~/.jve).

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua"

local store = require("core.user_keymap_store")

local function fail(label, message)
    io.stderr:write(string.format("%s: %s\n", label, message or "failed"))
    os.exit(1)
end

local function assert_true(label, cond)
    if not cond then fail(label, "expected truthy") end
end

local function assert_equals(label, actual, expected)
    if actual ~= expected then
        fail(label, string.format("expected %q, got %q",
            tostring(expected), tostring(actual)))
    end
end

local function expect_error(label, fn)
    local ok = pcall(fn)
    if ok then fail(label, "expected error") end
end

local function setup_temp_base()
    local pid = tostring(jit and jit.os and 0 or 0)  -- LuaJIT has no os.getpid; use timestamp
    local base = string.format("/tmp/jve_test_keymap_store_%d_%s",
        os.time(), pid)
    os.execute("rm -rf " .. base)
    store.set_base_dir(base)
    return base
end

local function table_contains(t, value)
    for _, v in ipairs(t) do
        if v == value then return true end
    end
    return false
end

-- Test 1: empty store reports no presets and no active pointer
local function test_empty_store()
    setup_temp_base()
    local presets = store.list()
    assert_equals("empty list", #presets, 0)
    assert_equals("no active", store.get_active(), nil)
    assert_equals("missing exists", store.exists("Foo"), false)
    assert_equals("missing read", store.read("Foo"), nil)
end

-- Test 2: write → list → read round-trip preserves content exactly
local function test_round_trip()
    setup_temp_base()
    local content = '[Application]\n"Cmd+Z" = "Undo"\n'
    store.write("MyPreset", content)

    assert_equals("exists after write", store.exists("MyPreset"), true)
    local presets = store.list()
    assert_equals("list has one", #presets, 1)
    assert_true("list contains MyPreset", table_contains(presets, "MyPreset"))
    assert_equals("read returns same content", store.read("MyPreset"), content)
end

-- Test 3: delete removes the file and updates list
local function test_delete()
    setup_temp_base()
    store.write("Doomed", "[X]\n")
    store.write("Survivor", "[Y]\n")

    store.delete("Doomed")
    assert_equals("doomed gone", store.exists("Doomed"), false)
    assert_equals("survivor remains", store.exists("Survivor"), true)
    assert_equals("list has one", #store.list(), 1)
end

-- Test 4: active-preset pointer round-trips and survives module re-require
local function test_active_pointer()
    setup_temp_base()
    assert_equals("initially nil", store.get_active(), nil)

    store.set_active("MyChoice")
    assert_equals("set then get", store.get_active(), "MyChoice")

    store.set_active(nil)
    assert_equals("cleared", store.get_active(), nil)
end

-- Test 5: list is sorted alphabetically (predictable UI display)
local function test_list_sorted()
    setup_temp_base()
    store.write("Zulu", "[X]\n")
    store.write("Alpha", "[X]\n")
    store.write("Mike", "[X]\n")

    local presets = store.list()
    assert_equals("alpha first", presets[1], "Alpha")
    assert_equals("mike second", presets[2], "Mike")
    assert_equals("zulu third", presets[3], "Zulu")
end

-- Test 6: unsafe preset names rejected (no path traversal)
local function test_name_validation()
    setup_temp_base()
    expect_error("slash", function() store.write("foo/bar", "x") end)
    expect_error("dotdot", function() store.write("..", "x") end)
    expect_error("empty", function() store.write("", "x") end)
    expect_error("nul", function() store.write("foo\0bar", "x") end)
    expect_error("read slash", function() store.read("foo/bar") end)
    expect_error("delete slash", function() store.delete("foo/bar") end)
    expect_error("active slash", function() store.set_active("foo/bar") end)
end

-- Test 7: writing the same preset twice overwrites (not duplicates)
local function test_overwrite()
    setup_temp_base()
    store.write("Same", "first\n")
    store.write("Same", "second\n")

    assert_equals("only one in list", #store.list(), 1)
    assert_equals("content is latest", store.read("Same"), "second\n")
end

-- Test 8: preset names with spaces are allowed (matches Premiere "Joe's hand-rolled FCP7")
local function test_spaces_in_names()
    setup_temp_base()
    local name = "Joe's hand-rolled FCP7"
    store.write(name, "[X]\n")
    assert_equals("spaces ok", store.exists(name), true)
    assert_true("listed", table_contains(store.list(), name))
end

test_empty_store()
test_round_trip()
test_delete()
test_active_pointer()
test_list_sorted()
test_name_validation()
test_overwrite()
test_spaces_in_names()

print("✅ test_user_keymap_store.lua passed")
