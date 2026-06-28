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
local function build_metadata_json(state, capture_dir)  -- luacheck: no unused args
    local signature  = require("bug_reporter.signature")
    local build_info = require("core.build_info")
    local dkjson     = require("dkjson")
    local last_commands = state.last_commands or { "ReportBug" }
    local metadata = {
        capture_type = "user_submitted",
        jve_sha = build_info.git_sha,
        last_cmd = last_commands[#last_commands - 1] or last_commands[1],
        last_err = nil,
        signature = signature.compute("user_submitted", last_commands, nil, state.title),
        text_only = state.text_only and true or false,
        ts = os.time(),
        user_desc = state.description,
        user_title = state.title,
    }
    local keys = {}
    for k in pairs(metadata) do keys[#keys + 1] = k end
    table.sort(keys)
    return dkjson.encode(metadata, { keyorder = keys })
end

local function zip_capture(capture_path, text_only)
    local zip_writer = require("bug_reporter.zip_writer")
    local capture_dir = capture_path:match("^(.*)/[^/]+$")
    assert(capture_dir, "report_bug.submit: could not derive capture_dir")
    local basename = capture_dir:match("([^/]+)$") or "capture"
    local files = { capture_path }
    if not text_only then
        table.insert(files, capture_dir .. "/slideshow.mp4")
    end
    local zip_path = capture_dir .. "/" .. basename .. ".zip"
    assert(zip_writer.zip_files(zip_path, files))
    local zf = assert(io.open(zip_path, "rb"))
    local bytes = zf:read("*a")
    zf:close()
    return zip_path, bytes, capture_dir
end

function M.submit(state, on_done)
    assert(state and type(state.is_submittable) == "function",
        "report_bug.submit: requires a submission_state instance")
    assert(state:is_submittable(),
        "report_bug.submit: state is not submittable (title is required)")
    assert(type(on_done) == "function",
        "report_bug.submit: on_done callback required (transport is async)")

    local install       = require("bug_reporter.install")
    local record = install.read()
    if not record then
        on_done(M.show_disabled_notice())
        return
    end

    local MAX_PAYLOAD_BYTES = 10 * 1024 * 1024
    local bug_reporter = require("bug_reporter")
    bug_reporter.capture_manual_async(state.title, state.description,
        function(capture_path, capture_err)
            assert(capture_path,
                "report_bug.submit: capture_manual_async returned nil: " .. tostring(capture_err))
            local zip_path, zip_bytes, capture_dir = zip_capture(capture_path, state.text_only)
            local metadata_json = build_metadata_json(state, capture_dir)

            -- FR-024a: client-side 10 MB cap (Worker returns 413
            -- payload_too_large above this). Clamp here so the user
            -- gets an actionable refusal instead of the generic reject.
            if #zip_bytes > MAX_PAYLOAD_BYTES then
                local mb = math.floor(#zip_bytes / (1024 * 1024))
                local msg = string.format(
                    "Bug report is too large to send (%d MB; max 10 MB). " ..
                    "Try the 'Text only' option to exclude the slideshow.", mb)
                log.warn("report_bug.submit: payload %d bytes exceeds %d cap — refusing post",
                    #zip_bytes, MAX_PAYLOAD_BYTES)
                on_done({ ok = false, zip_path = zip_path, user_message = msg })
                return
            end

            local transport     = require("bug_reporter.transport")
            local pending_queue = require("bug_reporter.pending_queue")
            local local_id = require("uuid").generate()

            transport.post_report(metadata_json, zip_bytes, local_id,
                record.install_id, record.nonce, function(result)
                    if result.ok then
                        log.event("Bug report sent: ref %s", tostring(result.ref_short))
                        on_done({ ok = true, ref_short = result.ref_short, zip_path = zip_path,
                            user_message = "Report sent — reference #" .. tostring(result.ref_short) })
                        return
                    end
                    if result.code == "rate_limited" then
                        on_done({ ok = false, zip_path = zip_path,
                            user_message = "Over today's submission cap — try again tomorrow" })
                        return
                    end
                    pending_queue.enqueue(zip_bytes, metadata_json, local_id)
                    on_done({ ok = false, zip_path = zip_path,
                        user_message = "Queued for retry on next launch" })
                end)
        end)
end

function M.show_disabled_notice()
    -- F12-while-disabled routes straight to the Privacy panel — the
    -- one place that re-enables. Loading is best-effort: if the panel
    -- can't be loaded (test mode without qt_constants), fall back to
    -- the text message so callers still get a user_message back.
    local msg = "Bug reporting is disabled. Open Privacy & Bug Reporting (Cmd+,) to re-enable."
    log.event("ReportBug invoked while disabled — opening Privacy panel + surfacing %q", msg)
    local ok_panel, panel = pcall(require, "bug_reporter.ui.privacy_panel")
    if ok_panel and type(panel.show) == "function" then
        local ok_show, show_err = pcall(panel.show)
        if not ok_show then
            log.warn("show_disabled_notice: privacy_panel.show failed: %s", tostring(show_err))
        end
    end
    return { ok = false, user_message = msg }
end

function M.register(executors, undoers, db)  -- luacheck: no unused args
    local function executor(command)  -- luacheck: no unused args
        local submission_state  = require("bug_reporter.ui.submission_state")
        local submission_dialog = require("bug_reporter.ui.submission_dialog")

        -- F12 just opens the dialog. The single capture happens inside
        -- M.submit when the user clicks Submit. Previously F12 ran one
        -- capture (gesture/log dump + slideshow ffmpeg) and Submit ran
        -- a second — duplicate beachball, duplicate disk write, and
        -- the F12-side capture's data was always thrown away because
        -- Submit re-captured from a fresh ring snapshot.
        local state = submission_state.new()
        local wrapper = submission_dialog.create(state)
        assert(wrapper and wrapper.dialog,
            "report_bug executor: submission_dialog.create returned no dialog")
        assert(qt_show_dialog,
            "report_bug executor: qt_show_dialog binding missing")
        qt_show_dialog(wrapper.dialog, false)

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
