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

-- Algorithm (per ENGINEERING.md 2.5):
--   1. capture via bug_reporter.capture_manual.
--   2. read install record (must exist — telemetry.init runs at app
--      startup and either registers or surfaces "disabled" message).
--   3. build metadata JSON with signature (T008) + last commands +
--      hardware fields.
--   4. zip capture.json (+ slideshow.mp4 unless text_only) into payload.
--   5. transport.post_report → on success show ref_short; on rate-limit
--      show cap message; on transport error enqueue for next-launch drain.
function M.submit(state)
    assert(state and type(state.is_submittable) == "function",
        "report_bug.submit: requires a submission_state instance")
    assert(state:is_submittable(),
        "report_bug.submit: state is not submittable (title is required)")

    local bug_reporter   = require("bug_reporter")
    local zip_writer     = require("bug_reporter.zip_writer")
    local install        = require("bug_reporter.install")
    local transport      = require("bug_reporter.transport")
    local signature      = require("bug_reporter.signature")
    local pending_queue  = require("bug_reporter.pending_queue")
    local build_info     = require("core.build_info")
    local dkjson         = require("dkjson")

    -- Phase B: gate on install record presence. telemetry.init prompts
    -- consent + register at startup; if the user declined we surface
    -- the "disabled" notice via report_bug.show_disabled_notice.
    local record = install.read()
    if not record then
        return M.show_disabled_notice()
    end

    local capture_path = bug_reporter.capture_manual(state.title, state.description)
    assert(capture_path, "report_bug.submit: capture_manual returned nil")
    local capture_dir = capture_path:match("^(.*)/[^/]+$")
    assert(capture_dir, "report_bug.submit: could not derive capture_dir")
    local basename = capture_dir:match("([^/]+)$") or "capture"

    local files = { capture_path }
    if not state.text_only then
        table.insert(files, capture_dir .. "/slideshow.mp4")
    end
    local zip_path = capture_dir .. "/" .. basename .. ".zip"
    assert(zip_writer.zip_files(zip_path, files))

    local zip_file = assert(io.open(zip_path, "rb"))
    local zip_bytes = zip_file:read("*a")
    zip_file:close()

    local last_commands = state.last_commands or { "ReportBug" }
    local sig = signature.compute("user_submitted", last_commands, nil, state.title)
    local metadata = {
        capture_type = "user_submitted",
        jve_sha = build_info.git_sha,
        last_cmd = last_commands[#last_commands - 1] or last_commands[1],
        last_err = nil,
        signature = sig,
        text_only = state.text_only and true or false,
        ts = os.time(),
        user_desc = state.description,
        user_title = state.title,
    }
    local metadata_keys = {}
    for k in pairs(metadata) do metadata_keys[#metadata_keys + 1] = k end
    table.sort(metadata_keys)
    local metadata_json = dkjson.encode(metadata, { keyorder = metadata_keys })

    local local_id = require("uuid").generate()
    local result = transport.post_report(metadata_json, zip_bytes, local_id,
        record.install_id, record.nonce)
    if result and result.ok then
        log.event("Bug report sent: ref %s", tostring(result.ref_short))
        return { ok = true, ref_short = result.ref_short, user_message =
            "Report sent — reference #" .. tostring(result.ref_short) }
    end
    if result and result.code == "rate_limited" then
        return { ok = false, user_message = "Over today's submission cap — try again tomorrow" }
    end
    pending_queue.enqueue(zip_bytes, metadata_json)
    return { ok = false, user_message = "Queued for retry on next launch" }
end

function M.show_disabled_notice()
    local msg = "Bug reporting is disabled; enable in Preferences → Privacy."
    log.event("ReportBug invoked while disabled — surfacing %q", msg)
    if _G.qt_constants and _G.qt_constants.DIALOG and _G.qt_constants.DIALOG.SHOW_MESSAGE then
        _G.qt_constants.DIALOG.SHOW_MESSAGE("Bug Reporting", msg)
    end
    return { ok = false, user_message = msg }
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
