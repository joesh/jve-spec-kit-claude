-- Feature 027 regression: Submit handler must pull title/description/
-- text_only from the actual Qt widgets, not from whatever the state
-- happened to hold before the user typed.
--
-- Live-smoke bug (2026-06-27): user filled in the title field and
-- clicked Submit; got "submission_dialog: Submit invoked but state is
-- not submittable — ignoring" because sync_state_from_widgets guarded
-- on `_G.qt_get_text` (a binding that does not exist) and silently
-- no-op'd, leaving state.title == "". Black-box: drive the dialog
-- through widget setters + on_submit, assert state model picked up
-- the typed values.
--
-- Run via --test mode (needs Qt widgets):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     "$(pwd)/tests/synthetic/integration/test_bug_reporter_submit_pulls_widget_text.lua"

print("=== test_bug_reporter_submit_pulls_widget_text.lua ===")

require("test_env")

local submission_state  = require("bug_reporter.ui.submission_state")
local submission_dialog = require("bug_reporter.ui.submission_dialog")

local state = submission_state.new()
local wrapper = submission_dialog.create(state)
assert(wrapper and wrapper.widgets, "submission_dialog.create must return widgets")

-- Simulate the user typing into the title/desc fields and checking
-- the text-only box. Goes through the canonical PROPERTIES setters
-- so this exercises the same path real Qt input events would take.
qt_constants.PROPERTIES.SET_TEXT(wrapper.widgets.title_edit, "Live-smoke title")
qt_constants.PROPERTIES.SET_TEXT(wrapper.widgets.desc_edit, "Steps to reproduce: press F12.")
qt_constants.PROPERTIES.SET_CHECKED(wrapper.widgets.text_only, true)

-- Sanity: state has NOT been mutated yet (sync is pull-at-Submit per
-- ui/submission_dialog.lua design comment).
assert(state.title == "", "state.title should still be empty before sync_state_from_widgets")

-- The widget→state pull is the unit under test; exercise it directly
-- via the public sync helper rather than going through on_submit,
-- which would invoke the full capture + transport pipeline.
assert(type(submission_dialog.sync_state_from_widgets) == "function",
    "submission_dialog must expose sync_state_from_widgets so the widget→state pull is testable in isolation")
submission_dialog.sync_state_from_widgets(state, wrapper.widgets)

assert(state.title == "Live-smoke title",
    "state.title must be pulled from title_edit, got: " .. tostring(state.title))
assert(state.description == "Steps to reproduce: press F12.",
    "state.description must be pulled from desc_edit, got: " .. tostring(state.description))
assert(state.text_only == true,
    "state.text_only must be pulled from text_only checkbox, got: " .. tostring(state.text_only))

print("✅ test_bug_reporter_submit_pulls_widget_text.lua passed")
