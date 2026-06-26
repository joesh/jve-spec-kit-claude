-- Bug-reporter telemetry orchestrator (feature 027 T037).
--
-- Sole entry point that composes consent + install state + heartbeat +
-- pending-queue drain. Called once from layout.lua (T050) between
-- main-window create and SHOW.
--
-- Algorithm (per ENGINEERING 2.5):
--   1. Read preference toggle (bug_reporter_enabled). If false → no-op.
--   2. Read install state. nil → consent dialog → register on Accept.
--   3. Read state again. If present → fire async /heartbeat (with
--      hardware re-snapshot iff jve_sha_at_register != build_info.sha
--      per FR-018).
--   4. After heartbeat, drain pending queue.

local dialog_prefs = require("core.dialog_prefs")
local build_info   = require("core.build_info")
local install      = require("bug_reporter.install")
local hardware     = require("bug_reporter.hardware_snapshot")
local log          = require("core.logger").for_area("ui")

local M = {}

local PREFS_FILENAME = "bug_reporter_prefs.json"
local PREF_KEY = "bug_reporter_enabled"

-- Test seams. Production code never assigns these; tests set them to
-- inject deterministic outcomes.
local test_consent_outcome
local test_pref
local last_f12_message

function M.set_consent_outcome_for_tests(outcome)
    assert(outcome == "accept" or outcome == "decline",
        "set_consent_outcome_for_tests: must be 'accept' or 'decline'")
    test_consent_outcome = outcome
end
function M.set_pref_for_tests(value)
    test_pref = value
    -- Also wipe the on-disk pref so a previous save_pref(false) from a
    -- decline path doesn't poison subsequent test scenarios.
    if value == nil then
        os.remove(dialog_prefs.path_for(PREFS_FILENAME))
    end
end
function M.f12_message_for_tests() return last_f12_message end

local function pref_enabled()
    if test_pref ~= nil then return test_pref end
    local path = dialog_prefs.path_for(PREFS_FILENAME)
    local prefs = dialog_prefs.load(path) or {}
    -- No prior pref entry = enabled-by-default-but-still-gated-by-consent.
    -- The consent dialog itself is the user's first opt-in. Once they
    -- accept, the pref is implicitly true. Once they decline, the pref
    -- is set false explicitly.
    if prefs[PREF_KEY] == false then return false end
    return true
end

local function save_pref(value)
    local path = dialog_prefs.path_for(PREFS_FILENAME)
    local prefs = dialog_prefs.load(path) or {}
    prefs[PREF_KEY] = value
    dialog_prefs.save(path, prefs)
end

local function show_consent()
    if test_consent_outcome then return test_consent_outcome end
    local consent_dialog = require("bug_reporter.ui.consent_dialog")
    return consent_dialog.prompt()
end

function M.register(consent_version)
    local snapshot = hardware.snapshot()
    local body = {
        install_id = install.generate_id(),
        schema_version = "1",
        jve_sha = build_info.git_sha,
        platform = snapshot.platform,
        os_version = snapshot.os_version,
        arch = snapshot.arch,
        cpu = snapshot.cpu,
        system_memory_mb = snapshot.system_memory_mb,
        gpu = snapshot.gpu,
        consent_version = consent_version,
    }
    local transport = require("bug_reporter.transport")
    local result = transport.post_register(body)
    if result and result.ok then
        install.write({
            install_id = body.install_id,
            nonce = result.nonce,
            consent_accepted_ts = os.time(),
            consent_version = consent_version,
            jve_sha_at_register = build_info.git_sha,
            hardware_snapshot = snapshot,
            country = result.country,
            timezone = result.timezone,
        })
        return true
    end
    log.warn("bug_reporter.telemetry: register failed: %s",
        tostring(result and result.code or "unknown"))
    return false
end

-- Apply a pref toggle (used by both T039's TogglePreferenceBugReporting
-- command in production and T028's tests). Turning ON without an
-- install file triggers consent + register so the next backend
-- interaction happens with a valid install_id (FR-002 / AS #15).
function M.apply_pref_toggle(value)
    save_pref(value)
    if value and install.read() == nil then
        local outcome = show_consent()
        if outcome == "accept" then M.register(1) end
    end
end
-- Tests use the same entry under its original name (T028 still calls
-- toggle_pref_for_tests directly); keep as a shallow alias so the
-- production callsite reads as production, not test-instrumentation.
M.toggle_pref_for_tests = M.apply_pref_toggle

-- The Submit path (used by T029). Pref OFF → notice; pref ON → delegate
-- to report_bug.submit which calls transport.post_report.
function M.attempt_submit_for_tests(state)
    if not pref_enabled() then
        last_f12_message = "Bug reporting is disabled; enable in Preferences → Privacy."
        return false
    end
    if install.read() == nil then return false end
    local report_bug = require("core.commands.report_bug")
    return report_bug.submit({
        title = state.title or "",
        description = state.description or "",
        text_only = state.text_only and true or false,
        is_submittable = function() return state.title and state.title ~= "" end,
    })
end

function M.heartbeat_for_tests()
    local record = install.read()
    if not record then return end
    local body = {
        ts = os.time(),
        jve_sha = build_info.git_sha,
    }
    if record.jve_sha_at_register ~= build_info.git_sha then
        body.hardware = hardware.snapshot()
    end
    local transport = require("bug_reporter.transport")
    return transport.post_heartbeat(body, record.install_id, record.nonce)
end

function M.init()
    if not pref_enabled() then
        last_f12_message = "Bug reporting is disabled; enable in Preferences → Privacy."
        return
    end
    local record = install.read()
    if record == nil then
        local outcome = show_consent()
        if outcome == "accept" then
            if not M.register(1) then return end
            record = install.read()
        else
            save_pref(false)
            last_f12_message = "Bug reporting is disabled; enable in Preferences → Privacy."
            return
        end
    end
    -- Heartbeat (re-snapshots hardware iff jve_sha bumped per FR-018).
    M.heartbeat_for_tests()
    -- Drain pending queue last.
    local pending_queue = require("bug_reporter.pending_queue")
    pending_queue.drain(record.install_id, record.nonce)
end

return M
