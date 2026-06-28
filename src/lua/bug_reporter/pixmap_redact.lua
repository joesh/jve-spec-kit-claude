-- Feature 027 FR-020a + ENGINEERING.md Rule 2.18: pixel-side redaction
-- POLICY lives here (in Lua); the C++ side exposes only two thin FFI
-- primitives: `qt_widget_geometry_in(widget, ancestor) → {x,y,w,h,visible}`
-- and `qt_pixmap_fill_rect(pixmap, x, y, w, h, r, g, b)`. The widget
-- list, mask color, and visibility-based skip rule are all decided here.
--
-- Lifecycle: UI modules call register(widget, label) at construction.
-- The bug-reporter's screenshot tick calls apply(pixmap, main_window)
-- post-grab, before the pixmap reaches the ring buffer.

local log = require("core.logger").for_area("ui")
local M = {}

-- Mask color (grey). Visible-but-content-stripped: the user can see
-- "this region was screenshot" without the dev seeing what was in it.
local MASK_R, MASK_G, MASK_B = 96, 96, 96

local entries = {}  -- list of {widget = ..., label = ...}

-- Register `widget` as visually sensitive. Idempotent for the same
-- widget reference. nil widget is a hard error — silent skip would
-- mean the widget never gets masked = privacy leak (FR-020a).
function M.register(widget, label)
    assert(widget, "pixmap_redact.register: widget required")
    for _, e in ipairs(entries) do
        if e.widget == widget then return end
    end
    entries[#entries + 1] = {widget = widget, label = label}
    log.event("pixmap_redact: %s registered for capture-time masking",
        tostring(label or "widget"))
end

-- Overpaint every registered widget's rect on `pixmap` using grey.
-- Widgets reporting visible=false (destroyed since register, hidden
-- tab) are skipped silently — they cannot leak content that isn't on
-- screen. Missing FFI primitives are a hard error: silent skip there
-- would ship an unredacted screenshot.
function M.apply(pixmap, ancestor)
    assert(pixmap, "pixmap_redact.apply: pixmap required")
    assert(ancestor, "pixmap_redact.apply: ancestor widget required")
    assert(type(qt_widget_geometry_in) == "function",
        "pixmap_redact.apply: qt_widget_geometry_in binding is missing — " ..
        "bug_reporter C++ side not linked OR test_env stub absent. Silently " ..
        "skipping would ship an unredacted screenshot.")
    assert(type(qt_pixmap_fill_rect) == "function",
        "pixmap_redact.apply: qt_pixmap_fill_rect binding is missing — " ..
        "bug_reporter C++ side not linked OR test_env stub absent. Silently " ..
        "skipping would ship an unredacted screenshot.")
    for _, e in ipairs(entries) do
        local g = qt_widget_geometry_in(e.widget, ancestor)
        if g and g.visible then
            qt_pixmap_fill_rect(pixmap, g.x, g.y, g.w, g.h, MASK_R, MASK_G, MASK_B)
        end
    end
end

-- Test seam: drop all registered widgets. Used by tests that need a
-- clean slate without reloading the module via package.loaded[...] = nil.
function M._reset_for_tests()
    entries = {}
end

return M
