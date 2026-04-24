#!/usr/bin/env luajit
-- Unit test T009: mixed-value detection across N inspectables (FR-014).
-- Black-box: uses stub inspectables exposing :get; no real DB required.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local sb = require("ui.inspector.selection_binding")

local function stub(values)
    return {
        _values = values,
        get = function(self, key) return self._values[key] end,
    }
end

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== Inspector: mixed-value detection unit test ===\n")

-- All same.
do
    local a = stub({ name = "Shared" })
    local b = stub({ name = "Shared" })
    local first, all_same = sb._detect_mixed_values({a, b}, "name")
    check("N=2 identical: all_same=true",      all_same == true)
    check("N=2 identical: first='Shared'",    first == "Shared")
end

-- Differing.
do
    local a = stub({ name = "X" })
    local b = stub({ name = "Y" })
    local _, all_same = sb._detect_mixed_values({a, b}, "name")
    check("N=2 differing: all_same=false", all_same == false)
end

-- N=5, one differs.
do
    local stubs = {
        stub({k = 1}), stub({k = 1}), stub({k = 1}), stub({k = 1}), stub({k = 2}),
    }
    local _, all_same = sb._detect_mixed_values(stubs, "k")
    check("N=5 with one outlier: all_same=false", all_same == false)
end

-- N=5, all identical.
do
    local stubs = {
        stub({k = 42}), stub({k = 42}), stub({k = 42}), stub({k = 42}), stub({k = 42}),
    }
    local first, all_same = sb._detect_mixed_values(stubs, "k")
    check("N=5 all same: all_same=true", all_same == true)
    check("N=5 all same: first=42",       first == 42)
end

-- Nil vs empty-string distinction.
do
    local a = stub({})                -- returns nil
    local b = stub({ note = "" })     -- returns ""
    local _, all_same = sb._detect_mixed_values({a, b}, "note")
    check("nil vs \"\": all_same=false", all_same == false)
end

-- Single inspectable (edge — minimum input).
do
    local a = stub({ x = "only" })
    local first, all_same = sb._detect_mixed_values({a}, "x")
    check("N=1: all_same=true",      all_same == true)
    check("N=1: first='only'",      first == "only")
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_mixed_value_detection.lua passed")
