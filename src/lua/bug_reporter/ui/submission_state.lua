-- Feature 027 T012: submission dialog state model (MVC model layer
-- per Constitution I — the dialog is a view that pulls from this).
--
-- Phase A fields: title (required for Submit), description (free
-- text), text_only (toggle that excludes slideshow.mp4 from the zip).
-- Phase B (T049) extends with telemetry_fields_about_to_ship and
-- captured_user_paths for the privacy preview section.
--
-- Pure data — no IO, no widgets. Every mutation emits
-- `bug_report_state_changed` so the view re-pulls. View NEVER reads
-- internals; it goes through getters.

local signals = require("core.signals")

local M = {}

local STATE_CHANGED = "bug_report_state_changed"

local SubmissionState = {}
SubmissionState.__index = SubmissionState

function M.new()
    return setmetatable({
        title = "",
        description = "",
        text_only = false,
    }, SubmissionState)
end

function SubmissionState:set_title(title)
    assert(type(title) == "string", "submission_state:set_title expects string")
    self.title = title
    signals.emit(STATE_CHANGED)
end

function SubmissionState:set_description(description)
    assert(type(description) == "string", "submission_state:set_description expects string")
    self.description = description
    signals.emit(STATE_CHANGED)
end

function SubmissionState:set_text_only(text_only)
    assert(type(text_only) == "boolean",
        "submission_state:set_text_only expects boolean")
    self.text_only = text_only
    signals.emit(STATE_CHANGED)
end

function SubmissionState:toggle_text_only()
    self.text_only = not self.text_only
    signals.emit(STATE_CHANGED)
end

-- FR-004: title is required for Submit to enable.
function SubmissionState:is_submittable()
    return self.title ~= nil and self.title ~= ""
end

M.STATE_CHANGED = STATE_CHANGED
return M
