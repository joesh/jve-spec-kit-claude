-- Bug-reporter consent dialog (feature 027 T038).
--
-- Modal. Body = embedded copy of specs/027-user-facing-bug/consent-text-v1.md
-- (loaded at module-load so the dialog is self-contained). User picks
-- Accept or Decline; result is returned to caller (telemetry.lua T037).
--
-- Consent text is VERSIONED. The integer below is bumped whenever the
-- text materially changes; old consents are invalidated by the
-- bug-reporter pipeline noticing version mismatch and re-prompting.

local qt = require("bug_reporter.qt_compat")
local path_utils = require("core.path_utils")
local consent    = require("bug_reporter.consent")

local M = {}

-- Re-export the canonical constant. Bump bug_reporter.consent's value
-- to trigger re-prompting on next launch (FR-002a).
M.CONSENT_VERSION = consent.CONSENT_VERSION

local CONSENT_TEXT_PATH = "specs/027-user-facing-bug/consent-text-v1.md"

local function load_consent_text()
    -- Resolve via repo-root-aware helper (handles dev tree + bundled
    -- jve.app/Contents/Resources/ layout). Missing artifact is a build
    -- packaging bug — fail loud, never fall back to an inline string
    -- that could drift from the versioned text.
    local p = path_utils.resolve_repo_path(CONSENT_TEXT_PATH)
    local f = io.open(p, "r")
    assert(f,
        "bug_reporter.consent_dialog: consent text not found at " .. p ..
        " — packaging bug? consent-text-v1.md must ship with the binary")
    local body = f:read("*a")
    f:close()
    return body
end

local CONSENT_TEXT = load_consent_text()

-- Public: prompt the user. Returns "accept" or "decline".
-- The dialog runs modally (qt_show_dialog with modal=true).
--
-- Click handlers go through the codebase's named-global pattern
-- (see ui/welcome_screen.lua) because qt_set_button_click_handler
-- only accepts a global-name string, not a function literal.
function M.prompt()
    local dialog = qt.CREATE_DIALOG("JVE — Privacy Consent", 640, 560)
    local vbox = qt.CREATE_LAYOUT("vertical")
    qt.SET_WIDGET_LAYOUT(dialog, vbox)

    local body = qt.CREATE_TEXT_EDIT(CONSENT_TEXT)
    qt.SET_WIDGET_PROPERTY(body, "readOnly", true)
    qt.LAYOUT_ADD_WIDGET(vbox, body)

    local btn_row = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(btn_row)
    local decline_btn = qt.CREATE_BUTTON("Decline")
    qt.LAYOUT_ADD_WIDGET(btn_row, decline_btn)
    local accept_btn = qt.CREATE_BUTTON("Accept")
    qt.LAYOUT_ADD_WIDGET(btn_row, accept_btn)
    qt.LAYOUT_ADD_LAYOUT(vbox, btn_row)

    local result = "decline"  -- default if window-closed without choice
    local accept_name = "__bug_reporter_consent_accept"
    local decline_name = "__bug_reporter_consent_decline"
    _G[accept_name] = function()
        result = "accept"
        qt.CLOSE_DIALOG(dialog, true)
    end
    _G[decline_name] = function()
        result = "decline"
        qt.CLOSE_DIALOG(dialog, false)
    end
    _G.qt_set_button_click_handler(accept_btn, accept_name)
    _G.qt_set_button_click_handler(decline_btn, decline_name)

    _G.qt_show_dialog(dialog, true)

    _G[accept_name] = nil
    _G[decline_name] = nil
    return result
end

return M
