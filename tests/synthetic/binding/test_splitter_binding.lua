-- Splitter binding error policy (run via `jve --test`).
--
-- Black-box: the splitter bindings must fail loudly on misuse rather than
-- silently no-op (Engineering 1.14 / 2.13 / 2.32). A direction string outside
-- the closed set, or a non-splitter widget passed where a splitter is
-- expected, is a caller bug — it must raise, not be swallowed. Mirrors the
-- error policy already enforced by set_contents_margins / set_layout_spacing.

print("=== test_splitter_binding.lua ===")

local LAYOUT = qt_constants.LAYOUT
local WIDGET = qt_constants.WIDGET

-- Happy path: both valid orientations construct.
local h_split = LAYOUT.CREATE_SPLITTER("horizontal")
local v_split = LAYOUT.CREATE_SPLITTER("vertical")
assert(h_split, "horizontal splitter created")
assert(v_split, "vertical splitter created")
print("  ✓ valid orientations construct")

-- Unknown direction must raise (was silently defaulting to horizontal).
local ok = pcall(LAYOUT.CREATE_SPLITTER, "diagonal")
assert(not ok, "unknown direction must raise, not default")
-- Missing direction must raise.
ok = pcall(LAYOUT.CREATE_SPLITTER)
assert(not ok, "missing direction must raise")
print("  ✓ bad/missing direction raises")

-- A non-splitter widget passed to the splitter-size bindings must raise.
local plain = WIDGET.CREATE()
assert(plain, "plain widget created")
ok = pcall(LAYOUT.SET_SPLITTER_SIZES, plain, {100, 100})
assert(not ok, "set_splitter_sizes on a non-splitter must raise")
ok = pcall(LAYOUT.GET_SPLITTER_SIZES, plain)
assert(not ok, "get_splitter_sizes on a non-splitter must raise")
print("  ✓ non-splitter widget raises")

-- Happy path round-trip: set then read back returns a 2-entry vector.
LAYOUT.ADD_WIDGET(h_split, WIDGET.CREATE())
LAYOUT.ADD_WIDGET(h_split, WIDGET.CREATE())
local set_ok = LAYOUT.SET_SPLITTER_SIZES(h_split, {200, 300})
assert(set_ok, "set on real splitter succeeds")
local sizes = LAYOUT.GET_SPLITTER_SIZES(h_split)
assert(type(sizes) == "table" and #sizes == 2, "get returns a 2-entry vector")
print("  ✓ real splitter set/get round-trips")

print("✅ test_splitter_binding.lua passed")
