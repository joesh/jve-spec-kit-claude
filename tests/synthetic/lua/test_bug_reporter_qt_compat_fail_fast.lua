-- Feature 027 qt_compat fail-fast sweep.
--
-- Domain: bug-reporter UI wrappers MUST fail loud when their backing
-- bindings are missing. Silent no-op (the prior behavior) masked
-- broken setup as working code that did nothing — the consent
-- dialog could "open" with no visible widgets and the user would
-- think bug reporting was off when in fact telemetry init had silently
-- broken. Two failure modes the wrapper MUST raise on:
--   (a) core.qt_constants not loaded at all → every wrapper raises
--   (b) wrapper called with an unsupported widget property → raises
--       with the property name in the message
-- Both raises MUST name the wrapper API so the stack trace is
-- actionable (FR-019a-style loud message).

print("=== test_bug_reporter_qt_compat_fail_fast.lua ===")
require("test_env")

-- (a) qt_constants absent → every typed wrapper raises.
do
    -- Plant a sentinel module that makes type(qt_mod)=="table" check
    -- in qt_compat.init fail. qt_compat treats a non-table loaded
    -- module the same as missing (sets cache to false).
    package.loaded["core.qt_constants"] = false
    package.loaded["bug_reporter.qt_compat"] = nil

    local qt = require("bug_reporter.qt_compat")
    local ok, err = pcall(qt.SET_TEXT, "fake_widget", "hi")
    assert(not ok,
        "SET_TEXT must raise when qt_constants is absent; instead it returned successfully")
    assert(tostring(err):find("SET_TEXT", 1, true),
        "qt_constants-missing message must name the wrapper API; got " .. tostring(err))
    assert(tostring(err):find("qt_constants", 1, true),
        "qt_constants-missing message must mention 'qt_constants'; got " .. tostring(err))

    package.loaded["bug_reporter.qt_compat"] = nil
    package.loaded["core.qt_constants"] = nil
end

-- (b) qt_constants stubbed → readOnly works, unknown property raises
--     with the prop name in the message.
do
    package.loaded["core.qt_constants"] = {
        DIALOG     = { CREATE = function() end, SHOW = function() end, CLOSE = function() end, SET_LAYOUT = function() end },
        LAYOUT     = {
            CREATE_VBOX = function() end, CREATE_HBOX = function() end,
            ADD_WIDGET = function() end, ADD_STRETCH = function() end,
            ADD_SPACING = function() end, ADD_LAYOUT = function() end,
            SET_WIDGET_LAYOUT = function() end,
        },
        WIDGET     = {
            CREATE = function() end, CREATE_LABEL = function() end,
            CREATE_BUTTON = function() end, CREATE_CHECKBOX = function() end,
            CREATE_LINE_EDIT = function() end, CREATE_TEXT_EDIT = function() end,
            CREATE_COMBOBOX = function() end, CREATE_GROUP_BOX = function() end,
            CREATE_PROGRESS_BAR = function() end,
        },
        PROPERTIES = {
            SET_TEXT = function() end, GET_TEXT = function() return "" end,
            SET_CHECKED = function() end, GET_CHECKED = function() return false end,
            SET_STYLE = function() end, SET_PLACEHOLDER_TEXT = function() end,
            ADD_COMBOBOX_ITEM = function() end,
            SET_COMBOBOX_CURRENT_INDEX = function() end,
            SET_MIN_HEIGHT = function() end,
        },
        CONTROL    = {
            SET_ENABLED = function() end,
            SET_TEXT_EDIT_READ_ONLY = function() end,
            SET_PROGRESS_BAR_RANGE = function() end,
            SET_PROGRESS_BAR_VALUE = function() end,
        },
    }
    package.loaded["bug_reporter.qt_compat"] = nil
    local qt = require("bug_reporter.qt_compat")

    -- Known property succeeds.
    local ok = pcall(qt.SET_WIDGET_PROPERTY, "w", "readOnly", true)
    assert(ok, "SET_WIDGET_PROPERTY('readOnly') must succeed when qt_constants is loaded")

    -- Unknown property raises with name + actionable hint.
    local ok2, err2 = pcall(qt.SET_WIDGET_PROPERTY, "w", "wordWrap", true)
    assert(not ok2,
        "SET_WIDGET_PROPERTY('wordWrap') must raise — silent no-op for unknown props " ..
        "is exactly the masked-bug pattern the fail-fast sweep removed")
    assert(tostring(err2):find("wordWrap", 1, true),
        "unknown-property error must name the property; got " .. tostring(err2))
    assert(tostring(err2):find("SET_WIDGET_PROPERTY", 1, true),
        "unknown-property error must name the wrapper API; got " .. tostring(err2))
end

print("✅ test_bug_reporter_qt_compat_fail_fast.lua passed")
