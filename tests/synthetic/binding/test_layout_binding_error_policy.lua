-- Layout binding error policy (run via `jve --test`).
--
-- Black-box: the layout-container bindings must fail loudly when handed a
-- non-null argument of the wrong type, instead of silently no-op'ing
-- (Engineering 1.14 / 2.13 / 2.32). Passing a plain widget where a layout
-- container is expected, or swapping the (widget, layout) argument order, is
-- a caller bug — it must raise. This mirrors the policy already enforced by
-- set_splitter_sizes / set_contents_margins / set_layout_spacing.
--
-- The lifecycle case (a destroyed QPointer auto-nulled during teardown) stays
-- a silent no-op and is intentionally NOT exercised here — it isn't
-- reproducible black-box without tearing down a live widget mid-call.

print("=== test_layout_binding_error_policy.lua ===")

local LAYOUT = qt_constants.LAYOUT
local WIDGET = qt_constants.WIDGET

-- ── Happy paths ────────────────────────────────────────────────────────
local widget = WIDGET.CREATE()
local vbox = LAYOUT.CREATE_VBOX()
assert(widget and vbox, "widget + vbox created")

assert(LAYOUT.SET_ON_WIDGET(widget, vbox), "set layout on widget succeeds")
assert(LAYOUT.ADD_WIDGET(vbox, WIDGET.CREATE()), "add widget to layout succeeds")
assert(LAYOUT.ADD_STRETCH(vbox), "add stretch with default factor succeeds")
assert(LAYOUT.ADD_STRETCH(vbox, 2), "add stretch with explicit factor succeeds")
assert(LAYOUT.ADD_SPACING(vbox, 8), "add spacing succeeds")

local child_box = LAYOUT.CREATE_HBOX()
assert(LAYOUT.ADD_LAYOUT(vbox, child_box), "nest layout in box succeeds")

-- A QSplitter is also a valid ADD_WIDGET container.
local split = LAYOUT.CREATE_SPLITTER("horizontal")
assert(LAYOUT.ADD_WIDGET(split, WIDGET.CREATE()), "add widget to splitter succeeds")
print("  ✓ happy paths succeed")

-- ── Misuse must raise ──────────────────────────────────────────────────
local plain = WIDGET.CREATE()

-- A plain widget is neither a QSplitter nor a QLayout container.
assert(not pcall(LAYOUT.ADD_WIDGET, plain, WIDGET.CREATE()),
    "ADD_WIDGET into a non-container widget must raise")

-- Swapped (widget, layout) order: a layout where a widget is expected.
assert(not pcall(LAYOUT.SET_ON_WIDGET, vbox, vbox),
    "SET_ON_WIDGET with a layout as the widget arg must raise")
-- A widget where a layout is expected.
assert(not pcall(LAYOUT.SET_ON_WIDGET, widget, widget),
    "SET_ON_WIDGET with a widget as the layout arg must raise")

-- SET_WIDGET_LAYOUT shares the same contract.
assert(not pcall(LAYOUT.SET_WIDGET_LAYOUT, widget, widget),
    "SET_WIDGET_LAYOUT with a widget as the layout arg must raise")

-- Box-only operations on a non-box container.
assert(not pcall(LAYOUT.ADD_STRETCH, plain),
    "ADD_STRETCH on a non-box must raise")
assert(not pcall(LAYOUT.ADD_SPACING, plain, 8),
    "ADD_SPACING on a non-box must raise")
assert(not pcall(LAYOUT.ADD_LAYOUT, plain, LAYOUT.CREATE_HBOX()),
    "ADD_LAYOUT with a non-box parent must raise")
print("  ✓ wrong-type args raise")

print("✅ test_layout_binding_error_policy.lua passed")
