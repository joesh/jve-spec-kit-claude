-- ReportBug command — capture + show dialog + on Submit, zip + reveal.
--
-- Feature 027 T014c: M.submit(state) is the public entry the dialog's
-- Submit handler invokes. Reads title/description/text_only from the
-- submission_state model (Constitution I MVC — the command knows the
-- state's public API, never reaches into widgets).

local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id = {},  -- auto-injected by menu system
        sequence_id = {}, -- auto-injected by menu system
    }
}

-- Algorithm (per ENGINEERING.md 2.5 — main function reads as a story,
-- helpers carry the mechanics):
--   1. capture via bug_reporter.capture_manual (writes capture.json +
--      slideshow.mp4 inside a per-capture directory).
--   2. pick the files we ship: capture.json always; slideshow.mp4
--      unless text_only is toggled (FR-006).
--   3. zip them flat into <capture_dir>/<basename>.zip via zip_writer.
--   4. reveal in Finder (or write to the test reveal hook).
--   5. return { ok=true, zip_path } so the dialog can show the
--      "Report sent — reference #<...>" confirmation.
function M.submit(state)
    assert(state and type(state.is_submittable) == "function",
        "report_bug.submit: requires a submission_state instance")
    assert(state:is_submittable(),
        "report_bug.submit: state is not submittable (title is required)")

    local bug_reporter = require("bug_reporter")
    local zip_writer   = require("bug_reporter.zip_writer")
    local reveal       = require("bug_reporter.reveal")

    local capture_path = bug_reporter.capture_manual(state.title, state.description)
    assert(capture_path,
        "report_bug.submit: bug_reporter.capture_manual returned nil — capture failed")

    -- capture_path is <capture_dir>/capture.json; derive the parent dir.
    local capture_dir = capture_path:match("^(.*)/[^/]+$")
    assert(capture_dir and capture_dir ~= "",
        "report_bug.submit: could not derive capture_dir from " .. capture_path)
    local basename = capture_dir:match("([^/]+)$") or "capture"

    local files = { capture_path }
    if not state.text_only then
        table.insert(files, capture_dir .. "/slideshow.mp4")
    end

    local zip_path = capture_dir .. "/" .. basename .. ".zip"
    local zip_ok, zip_err = zip_writer.zip_files(zip_path, files)
    assert(zip_ok, "report_bug.submit: zip_files failed — " .. tostring(zip_err))

    reveal.reveal(zip_path)

    log.event("Bug report packaged: %s", zip_path)
    return { ok = true, zip_path = zip_path }
end

function M.register(executors, undoers, db)  -- luacheck: no unused args
    local function executor(command)  -- luacheck: no unused args
        local bug_reporter      = require("bug_reporter")
        local submission_state  = require("bug_reporter.ui.submission_state")
        local submission_dialog = require("bug_reporter.ui.submission_dialog")

        -- Phase A: F12 captures first, then opens the review dialog.
        -- The dialog's Submit handler calls M.submit which re-runs
        -- capture_manual + zips. The duplicate capture is acceptable
        -- for Phase A (exit criterion is just Finder showing a clean
        -- zip); Phase B's T051 collapses both by deferring capture
        -- until Submit.
        local capture_path = bug_reporter.capture_manual("F12 user-triggered")
        if not capture_path then
            log.error("Bug report capture failed")
            return true
        end
        log.event("Bug report captured: %s", capture_path)

        local state = submission_state.new()
        local wrapper = submission_dialog.create(state)
        if wrapper and wrapper.dialog and _G.qt_show_dialog then
            _G.qt_show_dialog(wrapper.dialog, false)
        end

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
