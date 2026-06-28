-- Feature 027 FR-020a: pixmap_redact.register policy.
--
-- Domain:
--   (1) register(widget, label) MUST forward `widget` to the
--       qt_bug_reporter_redact_widget binding. Each call is one
--       registration — the binding handles dedup on the C++ side.
--   (2) register(nil, ...) MUST raise — silent skip is a privacy
--       leak by design (the widget never gets masked).
--   (3) If the binding is missing (e.g. C++ side not linked, or a
--       test stub absent), register MUST raise with a message that
--       names what was about to leak. Silent skip in this branch is
--       exactly the FR-019 regression we're guarding against.

print("=== test_bug_reporter_pixmap_redact.lua ===")
require("test_env")

-- Capture every call to the binding so we can assert exact-count
-- forwarding semantics.
local recorded = {}
_G.qt_bug_reporter_redact_widget = function(widget)
    recorded[#recorded + 1] = widget
end

package.loaded["bug_reporter.pixmap_redact"] = nil
local redact = require("bug_reporter.pixmap_redact")

-- (1) register forwards the widget exactly once per call.
do
    recorded = {}
    local fake_widget_a = { name = "tree_a" }
    local fake_widget_b = { name = "tree_b" }
    redact.register(fake_widget_a, "tree_a")
    redact.register(fake_widget_b, "tree_b")
    assert(#recorded == 2,
        "register called twice must forward twice (binding dedups, not the policy); got " ..
        #recorded)
    assert(recorded[1] == fake_widget_a,
        "first call must forward fake_widget_a verbatim")
    assert(recorded[2] == fake_widget_b,
        "second call must forward fake_widget_b verbatim")
end

-- (2) register(nil) MUST raise (the widget could not be masked).
do
    local ok, err = pcall(redact.register, nil, "should_have_been_tree")
    assert(not ok,
        "register(nil) must raise — silent skip is a privacy leak")
    assert(tostring(err):find("widget", 1, true),
        "nil-widget error must mention 'widget'; got " .. tostring(err))
end

-- (3) If the binding is missing, register MUST raise and the message
--     MUST name what was about to leak (the label) so the dev finds
--     the regression fast.
do
    local saved_binding = _G.qt_bug_reporter_redact_widget
    _G.qt_bug_reporter_redact_widget = nil
    package.loaded["bug_reporter.pixmap_redact"] = nil
    local redact_unbound = require("bug_reporter.pixmap_redact")
    local ok, err = pcall(redact_unbound.register, { name = "tree" }, "project_browser tree")
    assert(not ok,
        "register MUST raise when binding is missing — silent skip leaks the widget")
    assert(tostring(err):find("project_browser tree", 1, true),
        "missing-binding error must name the leaking widget ('project_browser tree'); got " ..
        tostring(err))
    assert(tostring(err):find("qt_bug_reporter_redact_widget", 1, true),
        "missing-binding error must name the binding so the dev knows where to look; got " ..
        tostring(err))
    -- Restore for any later test that runs in this process.
    _G.qt_bug_reporter_redact_widget = saved_binding
    package.loaded["bug_reporter.pixmap_redact"] = nil
end

print("✅ test_bug_reporter_pixmap_redact.lua passed")
