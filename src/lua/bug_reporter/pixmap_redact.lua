-- Feature 027 FR-020a: pixel-side redaction policy.
--
-- The C++ side owns ONLY the FFI (rule 2.18): a thin
-- `qt_bug_reporter_redact_widget(widget)` binding that records the
-- widget in its QPointer list for the next grab_window pass. This
-- Lua module owns the POLICY: which widgets count as sensitive,
-- whether a registration should be skipped, and how callers report
-- the binding's presence/absence.

local log = require("core.logger").for_area("ui")
local M = {}

-- Register `widget` as visually sensitive. Every subsequent screenshot
-- captured by the bug reporter overpaints this widget's rect before
-- the pixmap reaches the in-memory ring. Idempotent on the C++ side
-- (same widget → no duplicate entry).
--
-- The binding is registered at `BugReporter::registerBugReporterBindings`.
-- If it's missing — synthetic Lua test without --test mode, or a
-- bundling regression — fail loud: silently skipping registration is
-- exactly the FR-019 leak we're trying to prevent. Joe authorized
-- explicit test stubs (tests/test_env.lua) for synthetic coverage.
function M.register(widget, label)
    assert(widget, "pixmap_redact.register: widget required")
    assert(type(qt_bug_reporter_redact_widget) == "function",
        "pixmap_redact.register: qt_bug_reporter_redact_widget binding is missing — " ..
        "bug_reporter C++ side not linked OR test_env stub absent. Silently skipping " ..
        "would leak " .. tostring(label or "the widget's content") .. " into screenshots.")
    qt_bug_reporter_redact_widget(widget)
    log.event("pixmap_redact: %s registered for capture-time masking",
        tostring(label or "widget"))
end

return M
