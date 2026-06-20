--- Inspector panel background is theme-driven, not a hardcoded color.
---
--- Domain contract: the inspector body surface is the editor's "inspector
--- content" theme color (the same cool-tinted grey as the rest of the
--- chrome). The C++ widget binding must contribute NO color of its own —
--- color is the theme layer's job. Regression for the body rendering a
--- neutral grey (#2b2b2b) while the header tinted: the binding had baked
--- `background: #2b2b2b; border: 1px solid #444` into the container,
--- shadowing the token system.
---
--- Black-box: drives the real CREATE_INSPECTOR binding + inspector.mount,
--- then reads the container's resolved `styleSheet` property. Expected
--- color comes from the theme token, never from tracing the implementation.
---
--- Runs inside ./build/bin/jve --test.

local qt_constants = require("core.qt_constants")
local ui_constants = require("core.ui_constants")
local pump = require("synthetic.helpers.qt_event_pump").pump

print("=== test_inspector_panel_theme ===")

local CONTENT_BG = ui_constants.COLORS.INSPECTOR_CONTENT_BG
assert(type(CONTENT_BG) == "string" and CONTENT_BG:match("^#%x%x%x%x%x%x$"),
    "INSPECTOR_CONTENT_BG must be a hex color token; got " .. tostring(CONTENT_BG))

-- luacheck: globals qt_get_widget_property
assert(type(qt_get_widget_property) == "function",
    "qt_get_widget_property binding missing")

local function stylesheet_of(w)
    return qt_get_widget_property(w, "styleSheet") or ""
end

-- Every 6-digit hex literal present in a stylesheet string.
local function hexes_in(s)
    local out = {}
    for h in s:gmatch("#%x%x%x%x%x%x") do out[#out + 1] = h:lower() end
    return out
end

-- (1) The C++ binding must bake no color of its own.
local panel = qt_constants.WIDGET.CREATE_INSPECTOR()
assert(panel, "CREATE_INSPECTOR returned nil")
local baked = stylesheet_of(panel)
assert(baked == "", string.format(
    "inspector binding must contribute no color; CREATE_INSPECTOR baked a stylesheet: %q", baked))

-- (2) After the real mount, the container's background is the theme token,
--     carries no border, and contains no off-token color literal.
local inspector = require("ui.inspector")
inspector.mount(panel)
inspector.update_selection({}, "timeline")
qt_constants.DISPLAY.SHOW(panel)
pump(80)

local ss = stylesheet_of(panel)
assert(ss ~= "", "after mount the inspector container must be themed (got empty stylesheet)")

local bg = ss:match("background%s*:%s*(#%x%x%x%x%x%x)")
assert(bg, "inspector container stylesheet must set a background color; got: " .. ss)
assert(bg:lower() == CONTENT_BG:lower(), string.format(
    "inspector body must be the theme content color %s; got %s", CONTENT_BG, bg))

assert(not ss:lower():find("border"), string.format(
    "inspector container must carry no border (Joe: lose it); got: %s", ss))

for _, h in ipairs(hexes_in(ss)) do
    assert(h == CONTENT_BG:lower(), string.format(
        "inspector container stylesheet contains off-token color %s; only %s allowed", h, CONTENT_BG))
end

-- (3) The section surface — the widget that actually paints behind the
--     property rows — must be the same theme color, not a neutral grey.
--     This is where the user-visible "body" lives.
local collapsible_section = require("ui.collapsible_section")
local result = collapsible_section.create_section("Theme Probe")
local section = result.section
assert(section and section.main_widget,
    "create_section must return a section with a main_widget")

local section_ss = stylesheet_of(section.main_widget)
local section_bg = section_ss:match("background%-?color%s*:%s*(#%x%x%x%x%x%x)")
assert(section_bg, "section main widget must set a background color; got: " .. section_ss)
assert(section_bg:lower() == CONTENT_BG:lower(), string.format(
    "inspector section surface must be the theme content color %s; got %s", CONTENT_BG, section_bg))

print("✅ test_inspector_panel_theme passed")
