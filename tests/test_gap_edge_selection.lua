#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

local edge_utils = require("ui.timeline.edge_utils")

local function expect_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s (expected=%s, got=%s)", message or "values differ", tostring(expected), tostring(actual)))
    end
end

expect_equal(edge_utils.normalize_edge_type("in"), "in", "clip in-edge should remain 'in'")
expect_equal(edge_utils.normalize_edge_type("out"), "out", "clip out-edge should remain 'out'")
expect_equal(edge_utils.normalize_edge_type("gap_before"), "gap_before", "gap_before edge must stay gap_before")
expect_equal(edge_utils.normalize_edge_type("gap_after"), "gap_after", "gap_after edge must stay gap_after")
expect_equal(edge_utils.normalize_edge_type(nil), nil, "nil edge should remain nil")

print("✅ Gap edge normalization preserves gap identifiers")
