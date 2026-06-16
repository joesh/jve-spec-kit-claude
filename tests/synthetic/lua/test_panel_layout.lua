#!/usr/bin/env luajit
-- Black-box test for the panel layout topology + size validation.
-- Domain behavior: the editor's panel layout is a fixed set of named
-- regions. A persisted size record is usable only when it describes
-- exactly those regions and every region is at least minimally visible;
-- anything else must be rejected so the editor can fall back to defaults
-- instead of restoring a collapsed/garbled layout.

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"

require("test_env")

local panel_layout = require("ui.panel_layout")

local function assert_true(cond, msg)
    if not cond then error("FAIL: " .. msg, 2) end
end

local MIN_PX = 50

-- Topology: the top row holds four panels, the main column holds two rows.
assert_true(panel_layout.top_count() == 4, "top row has four panels")
assert_true(panel_layout.main_count() == 2, "main column has two rows")

-- Each panel is addressable by identity, in declared visual order.
assert_true(panel_layout.top_index("project_browser") == 1, "browser is leftmost")
assert_true(panel_layout.top_index("inspector") == 4, "inspector is rightmost")
assert_true(panel_layout.top_index("nonexistent") == nil, "unknown id has no index")

-- Defaults describe every region with a usable (>= min) size.
local def_top = panel_layout.default_top_sizes()
local def_main = panel_layout.default_main_sizes()
assert_true(#def_top == 4, "default top sizes cover all four panels")
assert_true(#def_main == 2, "default main sizes cover both rows")
for _, sz in ipairs(def_top) do assert_true(sz >= MIN_PX, "default top size visible") end
for _, sz in ipairs(def_main) do assert_true(sz >= MIN_PX, "default main size visible") end

-- A well-formed, non-degenerate record is accepted.
assert_true(panel_layout.validate_sizes(
    { top = {300, 300, 300, 300}, main = {450, 450} }, MIN_PX),
    "well-formed sizes accepted")

-- Wrong panel count is rejected (e.g. a stale 3-panel record from before
-- a fourth panel existed — no silent migration, just reject → defaults).
assert_true(not panel_layout.validate_sizes(
    { top = {400, 400, 400}, main = {450, 450} }, MIN_PX),
    "three-panel top rejected")

-- A region collapsed below the minimum is rejected (would hide a panel).
assert_true(not panel_layout.validate_sizes(
    { top = {300, 300, 300, 0}, main = {450, 450} }, MIN_PX),
    "collapsed top panel rejected")
assert_true(not panel_layout.validate_sizes(
    { top = {300, 300, 300, 300}, main = {900, 10} }, MIN_PX),
    "collapsed main row rejected")

-- Missing/garbage shapes are rejected, not crashed on.
assert_true(not panel_layout.validate_sizes(nil, MIN_PX), "nil rejected")
assert_true(not panel_layout.validate_sizes({ top = {300,300,300,300} }, MIN_PX), "missing main rejected")
assert_true(not panel_layout.validate_sizes({ top = "x", main = {450,450} }, MIN_PX), "non-table top rejected")

print("✅ test_panel_layout.lua passed")
