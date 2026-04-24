#!/usr/bin/env luajit
-- Regression test: empty-input commit on a TIMECODE field is classified as
-- "revert" (no-op write), not "commit" (write nil).
--
-- Bug reproduction (from TSO 2026-04-20 10:26:59):
--   User blurred an empty mark_in field. editingFinished handler parsed "" →
--   (nil, nil) — empty input, no parse error. Handler nonetheless fired
--   on_commit(entry, nil) → inspectable:set("mark_in", {value=nil, property_type="TIMECODE"})
--   → TIMECODE assert: "value must be a number, got nil" → crash log, no undo
--   entry recorded.
--
-- Spec edge case (spec.md §Edge Cases): "Field commit while the focused field
-- is empty: the commit is treated as 'no change' for that field (empty string
-- is not written for numeric or timecode fields)."

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Need qt_signals to be require-able but not actually called.
_G.qt_signals = nil

-- Stub qt_constants enough for field_widget to require cleanly.
package.loaded["core.qt_constants"] = {
    WIDGET     = { CREATE_LINE_EDIT = function() return {} end },
    PROPERTIES = {},
    LAYOUT     = {},
    DISPLAY    = {},
    CONTROL    = {},
    GEOMETRY   = {},
}
package.loaded["core.qt_signals"] = {
    connect        = function() return 1 end,
    onTextChanged  = function() return 1 end,
}

local field_widget = require("ui.inspector.field_widget")
assert(type(field_widget._classify_commit) == "function",
    "field_widget._classify_commit must be exposed for this regression test")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1; print(string.format("FAIL: %s — got %q, want %q", label, tostring(got), tostring(want))) end
end

print("=== field_widget: commit classification (empty TIMECODE regression) ===\n")

-- Valid typed value → commit.
check("valid integer → commit",      field_widget._classify_commit(42, nil),   "commit")
check("valid string → commit",       field_widget._classify_commit("abc", nil),"commit")
check("valid TIMECODE frame → commit",field_widget._classify_commit(240, nil), "commit")

-- Empty input → revert (no-change).
check("nil value, nil error → revert", field_widget._classify_commit(nil, nil), "revert")

-- Parse error → error (keep bad text).
check("nil value, error msg → error",  field_widget._classify_commit(nil, "not a number"), "error")
check("also-nil-with-other-err → error", field_widget._classify_commit(nil, "invalid timecode"), "error")

-- Crucial: empty value is NEVER "commit".
-- If this test passes, the editingFinished handler cannot reach the
-- on_commit branch with a nil value. That's the exact crash path from TSO.
for _, err in ipairs({ nil, false }) do
    local action = field_widget._classify_commit(nil, err)
    if action == "commit" then
        fail = fail + 1
        print(string.format("FAIL: nil value classified as commit (err=%s) — would recreate the mark_in crash", tostring(err)))
    else
        pass = pass + 1
    end
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_commit_classification.lua passed")
