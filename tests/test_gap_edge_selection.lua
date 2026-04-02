#!/usr/bin/env luajit

-- Test edge_utils.to_bracket() — with gap-as-clip, gap clips use standard
-- "in"/"out" edge types. No gap_before/gap_after mapping needed.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

local edge_utils = require("core.edge_utils")

local function expect_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s (expected=%s, got=%s)", message or "values differ", tostring(expected), tostring(actual)))
    end
end

-- Standard edge types pass through unchanged
expect_equal(edge_utils.to_bracket("in"), "in", "clip in-edge maps to 'in'")
expect_equal(edge_utils.to_bracket("out"), "out", "clip out-edge maps to 'out'")
expect_equal(edge_utils.to_bracket(nil), nil, "nil edge returns nil")

print("✅ Edge bracket conversion tests passed")
