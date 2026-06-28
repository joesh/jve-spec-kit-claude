-- Bug-reporter Privacy panel (feature 027 FR-002 / FR-009).
--
-- One-stop UI for the bug-reporter's identity + consent state. Shown
-- by the ShowBugReporterPrivacy command (Cmd+, by default) and by
-- report_bug.show_disabled_notice when F12 is pressed while disabled.
--
-- Surface:
--   - Read-only summary: install_id, jve_sha_at_register,
--     consent_version, consent_accepted_ts (formatted ISO-8601).
--   - "Bug reporting enabled" checkbox — drives
--     TogglePreferenceBugReporting via telemetry.apply_pref_toggle so
--     turning ON triggers /register (FR-002 / AS #15) and turning OFF
--     stops the capture pipeline + heartbeat.
--   - "Revoke and re-prompt" button — deletes ~/.jve/install_id.json
--     so the next launch consent-prompts fresh. Until relaunch the
--     current session continues using its in-memory nonce; explained
--     in the status_label after the button is clicked.
--   - Close button.
--
-- Constitution I MVC: this module owns widgets; state lives in
-- install.read() + bug_reporter_prefs.json. No widget value is
-- authoritative — every read pulls from the file.

local qt           = require("bug_reporter.qt_compat")
local install      = require("bug_reporter.install")
local consent      = require("bug_reporter.consent")
local dialog_prefs = require("core.dialog_prefs")
local qt_signals   = require("core.qt_signals")
local log          = require("core.logger").for_area("ui")

local M = {}

local PREFS_FILENAME = "bug_reporter_prefs.json"
local PREF_KEY       = "bug_reporter_enabled"

local function format_ts(unix_ts)
    if type(unix_ts) ~= "number" or unix_ts <= 0 then return "(unknown)" end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", unix_ts)
end

local function build_status_text(record)
    if not record then
        return table.concat({
            "Status: bug reporting NOT YET REGISTERED.",
            "",
            "No ~/.jve/install_id.json on disk. Enabling bug reporting",
            "below will prompt for consent and register this install.",
        }, "\n")
    end
    local current_consent = consent.CONSENT_VERSION
    local consent_stale = (record.consent_version ~= current_consent)
    return table.concat({
        "Identity (visible only to Joe — never shared with anyone else):",
        "  install_id:         " .. tostring(record.install_id),
        "  jve_sha (registered): " .. tostring(record.jve_sha_at_register or "?"),
        "  consent_version:    " .. tostring(record.consent_version) ..
            (consent_stale and (" (stale; current is " .. current_consent .. ")") or ""),
        "  consent_accepted:   " .. format_ts(record.consent_accepted_ts),
        "  last_seen_country:  " .. tostring(record.country or "?"),
        "",
        "File: ~/.jve/install_id.json (mode 0600, atomic-write protected).",
    }, "\n")
end

local function load_pref_enabled()
    local prefs = dialog_prefs.load(dialog_prefs.path_for(PREFS_FILENAME))
    -- nil (never toggled) = enabled-by-default per
    -- TogglePreferenceBugReporting's three-state semantics.
    if prefs[PREF_KEY] == nil then return true end
    return prefs[PREF_KEY] and true or false
end

-- Module-level so it's directly testable without driving the dialog.
-- Flips the runtime state via telemetry AND persists the pref to disk
-- so TogglePreferenceBugReporting's nil/true/false semantics stay in
-- sync. Returns the new boolean for the caller to display.
function M.apply_toggle(new_value)
    assert(type(new_value) == "boolean",
        "privacy_panel.apply_toggle: new_value must be boolean; got " .. type(new_value))
    local telemetry = require("bug_reporter.telemetry")
    telemetry.apply_pref_toggle(new_value)
    local prefs = dialog_prefs.load(dialog_prefs.path_for(PREFS_FILENAME))
    prefs[PREF_KEY] = new_value
    dialog_prefs.save(dialog_prefs.path_for(PREFS_FILENAME), prefs)
    log.event("PrivacyPanel: bug_reporter_enabled = %s", tostring(new_value))
    return new_value
end

-- Delete the install file so the next launch's telemetry.init treats
-- this as a fresh install and re-prompts. Returns "revoked" if a file
-- existed and was deleted, "absent" if there was nothing to remove.
-- Module-level so the test can drive it without needing a dialog.
function M.revoke()
    local home = os.getenv("HOME")
    assert(home and home ~= "", "PrivacyPanel.revoke: HOME unset")
    local p = home .. "/.jve/install_id.json"
    local f = io.open(p, "r")
    if f then
        f:close()
        local ok, err = os.remove(p)
        assert(ok, "PrivacyPanel.revoke: os.remove " .. p .. " failed: " .. tostring(err))
        log.event("PrivacyPanel: revoked — removed %s", p)
        return "revoked"
    end
    log.event("PrivacyPanel: revoke — %s already absent", p)
    return "absent"
end

-- Public: show the modal. Returns nothing (state changes hit disk).
function M.show()
    local dialog = qt.CREATE_DIALOG("JVE — Privacy & Bug Reporting", 620, 520)
    local vbox = qt.CREATE_LAYOUT("vertical")
    qt.SET_WIDGET_LAYOUT(dialog, vbox)

    local record = install.read()
    local status = qt.CREATE_TEXT_EDIT(build_status_text(record))
    qt.SET_WIDGET_PROPERTY(status, "readOnly", true)
    qt.LAYOUT_ADD_WIDGET(vbox, status)

    local enabled = load_pref_enabled()
    local toggle = qt.CREATE_CHECKBOX("Enable bug reporting (telemetry + F12 submit)")
    qt.SET_CHECKED(toggle, enabled)
    qt.LAYOUT_ADD_WIDGET(vbox, toggle)

    local action_label = qt.CREATE_LABEL("")
    qt.LAYOUT_ADD_WIDGET(vbox, action_label)

    local btn_row = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(btn_row)
    local revoke_btn = qt.CREATE_BUTTON("Revoke and re-prompt next launch")
    qt.LAYOUT_ADD_WIDGET(btn_row, revoke_btn)
    local close_btn = qt.CREATE_BUTTON("Close")
    qt.LAYOUT_ADD_WIDGET(btn_row, close_btn)
    qt.LAYOUT_ADD_LAYOUT(vbox, btn_row)

    local revoke_name = "__jve_privacy_panel_revoke"
    local close_name  = "__jve_privacy_panel_close"

    local function clear_globals()
        _G[revoke_name] = nil
        _G[close_name]  = nil
    end

    local toggle_conn = qt_signals.connect(toggle, "clicked", function()
        local new_value = qt.GET_CHECKED(toggle) and true or false
        M.apply_toggle(new_value)
        qt.SET_TEXT(action_label,
            new_value and "Bug reporting enabled." or "Bug reporting disabled.")
    end)
    assert(toggle_conn, "PrivacyPanel: failed to connect toggle.clicked")

    _G[revoke_name] = function()
        local outcome = M.revoke()
        if outcome == "revoked" then
            qt.SET_TEXT(action_label,
                "Revoked. Quit and relaunch JVE — you will be re-prompted for consent.")
        else
            qt.SET_TEXT(action_label,
                "No install record on disk; nothing to revoke. Next launch will prompt for consent.")
        end
    end

    _G[close_name] = function()
        qt_signals.disconnect(toggle, "clicked")
        clear_globals()
        qt.CLOSE_DIALOG(dialog, true)
    end

    qt_set_button_click_handler(revoke_btn, revoke_name)
    qt_set_button_click_handler(close_btn,  close_name)

    qt_show_dialog(dialog, true)
    qt_signals.disconnect(toggle, "clicked")
    clear_globals()
end

return M
