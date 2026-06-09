#!/usr/bin/env luajit
-- Unit test T012c: compute_mode pure helper.
-- Derived from FR-005, FR-005a, FR-007, FR-008.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want)))
    end
end

print("=== Inspector: compute_mode unit test ===\n")

-- Empty selection → "empty".
check("empty", sb._compute_mode({ size = 0, schema_counts = {}, all_support_multi_edit = false }),
    "empty")

-- Single item → "single".
check("single clip", sb._compute_mode({
    size = 1, schema_counts = { clip = 1 }, all_support_multi_edit = true }), "single")
check("single sequence", sb._compute_mode({
    size = 1, schema_counts = { sequence = 1 }, all_support_multi_edit = false }), "single")

-- Multi same schema, all support multi-edit → "multi_edit".
check("3 clips (all multi)", sb._compute_mode({
    size = 3, schema_counts = { clip = 3 }, all_support_multi_edit = true }), "multi_edit")

-- Multi same schema, some don't support multi-edit → "multi_read_only".
check("3 sequences (some read-only)", sb._compute_mode({
    size = 3, schema_counts = { sequence = 3 }, all_support_multi_edit = false }),
    "multi_read_only")

-- Mixed schemas → "heterogeneous".
check("1 clip + 1 sequence", sb._compute_mode({
    size = 2, schema_counts = { clip = 1, sequence = 1 }, all_support_multi_edit = false }),
    "heterogeneous")
check("3 clips + 2 sequences", sb._compute_mode({
    size = 5, schema_counts = { clip = 3, sequence = 2 }, all_support_multi_edit = true }),
    "heterogeneous")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_compute_mode.lua passed")
