-- Feature 027 FR-020a + ENGINEERING.md Rule 2.18 (FFI separation):
-- redaction POLICY lives in Lua; C++ exposes only thin geometry +
-- pixmap-fill primitives. This test pins that contract.
--
-- Domain:
--   (1) register(widget, label) MUST raise on nil widget (silent skip
--       = the widget never gets masked = privacy leak).
--   (2) apply(pixmap, ancestor) MUST iterate every registered widget,
--       fetch its rect via qt_widget_geometry_in, and fill that rect
--       on the pixmap via qt_pixmap_fill_rect using the mask color
--       (96,96,96 grey — visible-but-content-stripped).
--   (3) Widgets whose geometry-query reports !visible MUST be skipped
--       (destroyed-between-register-and-grab is the canonical case).
--   (4) If either FFI primitive is missing, apply MUST raise and
--       name the absent binding so the dev finds the regression fast.

print("=== test_bug_reporter_pixmap_redact.lua ===")
require("test_env")

-- Test seam: replace the FFI primitives so we can observe the policy
-- in isolation. Records every fill the policy issues.
local geometry_calls = {}
local fill_calls = {}
local fake_geometry = {}  -- widget_userdata → geometry table

_G.qt_widget_geometry_in = function(widget, ancestor)
    geometry_calls[#geometry_calls + 1] = {widget = widget, ancestor = ancestor}
    return fake_geometry[widget]
end
_G.qt_pixmap_fill_rect = function(pixmap, x, y, w, h, r, g, b)
    fill_calls[#fill_calls + 1] = {pixmap = pixmap, x = x, y = y, w = w, h = h,
        r = r, g = g, b = b}
end

package.loaded["bug_reporter.pixmap_redact"] = nil
local redact = require("bug_reporter.pixmap_redact")

local fake_pixmap = { __tag = "QPixmap" }
local fake_ancestor = { __tag = "QWidget:main" }
local widget_a = { __tag = "QWidget:tree_a" }
local widget_b = { __tag = "QWidget:tree_b" }
local widget_gone = { __tag = "QWidget:destroyed" }

-- (1) register(nil) MUST raise.
do
    local ok, err = pcall(redact.register, nil, "should_have_been_tree")
    assert(not ok,
        "register(nil) must raise — silent skip is a privacy leak")
    assert(tostring(err):find("widget", 1, true),
        "nil-widget error must mention 'widget'; got " .. tostring(err))
end

-- (2) Two visible widgets → two fills with mask grey (96,96,96), each
--     using the geometry returned by qt_widget_geometry_in.
do
    geometry_calls = {}
    fill_calls = {}
    fake_geometry[widget_a] = {x = 10, y = 20, w = 100, h = 200, visible = true}
    fake_geometry[widget_b] = {x = 300, y = 400, w = 150, h = 50,  visible = true}
    redact.register(widget_a, "tree_a")
    redact.register(widget_b, "tree_b")
    redact.apply(fake_pixmap, fake_ancestor)

    assert(#geometry_calls == 2,
        "apply must geometry-query every registered widget; got " ..
        #geometry_calls)
    assert(geometry_calls[1].widget == widget_a and geometry_calls[1].ancestor == fake_ancestor,
        "geometry-query #1 must use widget_a + ancestor")
    assert(geometry_calls[2].widget == widget_b and geometry_calls[2].ancestor == fake_ancestor,
        "geometry-query #2 must use widget_b + ancestor")

    assert(#fill_calls == 2,
        "apply must issue one fill per visible widget; got " .. #fill_calls)
    assert(fill_calls[1].pixmap == fake_pixmap, "fill #1 must target the pixmap")
    assert(fill_calls[1].x == 10 and fill_calls[1].y == 20
        and fill_calls[1].w == 100 and fill_calls[1].h == 200,
        "fill #1 rect must match widget_a's geometry verbatim")
    assert(fill_calls[1].r == 96 and fill_calls[1].g == 96 and fill_calls[1].b == 96,
        "fill #1 must use mask grey (96,96,96)")
    assert(fill_calls[2].x == 300 and fill_calls[2].y == 400
        and fill_calls[2].w == 150 and fill_calls[2].h == 50,
        "fill #2 rect must match widget_b's geometry verbatim")
end

-- (3) Destroyed-since-register widget (visible=false) MUST be skipped
--     silently — its geometry-query returns visible=false, no fill.
do
    geometry_calls = {}
    fill_calls = {}
    package.loaded["bug_reporter.pixmap_redact"] = nil
    redact = require("bug_reporter.pixmap_redact")
    fake_geometry[widget_a] = {x = 10, y = 20, w = 100, h = 200, visible = true}
    fake_geometry[widget_gone] = {x = 0, y = 0, w = 0, h = 0, visible = false}
    redact.register(widget_a, "tree_a")
    redact.register(widget_gone, "tree_gone")
    redact.apply(fake_pixmap, fake_ancestor)
    assert(#fill_calls == 1,
        "apply must skip !visible widgets; expected 1 fill, got " .. #fill_calls)
    assert(fill_calls[1].x == 10,
        "the surviving fill must be for widget_a, not the destroyed one")
end

-- (4) Missing FFI → apply raises and names the binding.
do
    package.loaded["bug_reporter.pixmap_redact"] = nil
    local saved_g = _G.qt_widget_geometry_in
    _G.qt_widget_geometry_in = nil
    local redact_missing = require("bug_reporter.pixmap_redact")
    fake_geometry[widget_a] = {x = 1, y = 2, w = 3, h = 4, visible = true}
    redact_missing.register(widget_a, "tree_a")
    local ok, err = pcall(redact_missing.apply, fake_pixmap, fake_ancestor)
    assert(not ok,
        "apply MUST raise when qt_widget_geometry_in is missing — silent " ..
        "skip = unredacted screenshot ships")
    assert(tostring(err):find("qt_widget_geometry_in", 1, true),
        "missing-binding error must name the binding; got " .. tostring(err))
    _G.qt_widget_geometry_in = saved_g
    package.loaded["bug_reporter.pixmap_redact"] = nil
end

do
    package.loaded["bug_reporter.pixmap_redact"] = nil
    local saved_f = _G.qt_pixmap_fill_rect
    _G.qt_pixmap_fill_rect = nil
    local redact_missing = require("bug_reporter.pixmap_redact")
    fake_geometry[widget_a] = {x = 1, y = 2, w = 3, h = 4, visible = true}
    redact_missing.register(widget_a, "tree_a")
    local ok, err = pcall(redact_missing.apply, fake_pixmap, fake_ancestor)
    assert(not ok,
        "apply MUST raise when qt_pixmap_fill_rect is missing")
    assert(tostring(err):find("qt_pixmap_fill_rect", 1, true),
        "missing-binding error must name the binding; got " .. tostring(err))
    _G.qt_pixmap_fill_rect = saved_f
    package.loaded["bug_reporter.pixmap_redact"] = nil
end

print("✅ test_bug_reporter_pixmap_redact.lua passed")
