#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

local edge_utils = require("ui.timeline.edge_utils")

local function expect_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s (expected=%s, got=%s)", message or "values differ", tostring(expected), tostring(actual)))
    end
end

-- Test to_bracket() conversion for rendering gap edges as clip boundaries
expect_equal(edge_utils.to_bracket("in"), "in", "clip in-edge maps to 'in'")
expect_equal(edge_utils.to_bracket("out"), "out", "clip out-edge maps to 'out'")
expect_equal(edge_utils.to_bracket("gap_before"), "out", "gap_before renders as right-edge bracket")
expect_equal(edge_utils.to_bracket("gap_after"), "in", "gap_after renders as left-edge bracket")
expect_equal(edge_utils.to_bracket(nil), nil, "nil edge returns nil")

print("✅ Gap edge bracket conversion tests passed")
