--- preferences_panel.lua
-- Bug reporter preferences UI panel (pure Lua + Qt bindings)
local youtube_oauth = require("bug_reporter.youtube_oauth")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local _bug_submission = require("bug_reporter.bug_submission")  -- luacheck: ignore (loaded for side effects)
local utils = require("bug_reporter.utils")
local log = require("core.logger").for_area("ui")
local qt = require("bug_reporter.qt_compat")

local PreferencesPanel = {}

-- Create preferences panel widget
-- @return: QWidget containing preferences UI
-- Build the "Automatic Capture" group: enable checkbox + ring-buffer size.
-- Returns the group widget and the input widgets the caller wants to read
-- back when saving preferences.
local function build_capture_section()
    local group = qt.CREATE_GROUP_BOX("Automatic Capture")
    local layout = qt.CREATE_LAYOUT("vertical")

    local enable_checkbox = qt.CREATE_CHECKBOX(
        "Enable automatic gesture and screenshot capture")
    qt.SET_CHECKED(enable_checkbox, true)
    qt.LAYOUT_ADD_WIDGET(layout, enable_checkbox)

    local desc = qt.CREATE_LABEL(
        "Continuously captures gestures and screenshots for bug reporting")
    qt.SET_WIDGET_STYLE(desc, "color: gray; font-size: 10pt;")
    qt.LAYOUT_ADD_WIDGET(layout, desc)

    qt.LAYOUT_ADD_SPACING(layout, 5)

    local row = qt.CREATE_LAYOUT("horizontal")
    local buffer_gestures = qt.CREATE_LINE_EDIT("200")
    qt.LAYOUT_ADD_WIDGET(row, qt.CREATE_LABEL("Ring buffer size:"))
    qt.LAYOUT_ADD_WIDGET(row, buffer_gestures)
    qt.LAYOUT_ADD_WIDGET(row, qt.CREATE_LABEL("gestures"))
    qt.LAYOUT_ADD_STRETCH(row)
    qt.LAYOUT_ADD_LAYOUT(layout, row)

    qt.SET_WIDGET_LAYOUT(group, layout)
    return group, enable_checkbox, buffer_gestures
end

-- Build the YouTube integration group: status label + auth buttons +
-- privacy combo. Returns the group plus everything the caller wires up.
local function build_youtube_section()
    local group = qt.CREATE_GROUP_BOX("YouTube Integration")
    local layout = qt.CREATE_LAYOUT("vertical")

    local status = qt.CREATE_LABEL("Status: Not configured")
    qt.SET_WIDGET_STYLE(status, "color: red;")
    qt.LAYOUT_ADD_WIDGET(layout, status)
    if youtube_oauth.is_authenticated() then
        qt.SET_TEXT(status, "Status: Authenticated ✓")
        qt.SET_WIDGET_STYLE(status, "color: green;")
    end

    qt.LAYOUT_ADD_SPACING(layout, 5)

    local btn_row = qt.CREATE_LAYOUT("horizontal")
    local configure_btn = qt.CREATE_BUTTON("Configure Credentials...")
    local auth_btn      = qt.CREATE_BUTTON("Authorize YouTube")
    local logout_btn    = qt.CREATE_BUTTON("Logout")
    qt.LAYOUT_ADD_WIDGET(btn_row, configure_btn)
    qt.LAYOUT_ADD_WIDGET(btn_row, auth_btn)
    qt.LAYOUT_ADD_WIDGET(btn_row, logout_btn)
    qt.LAYOUT_ADD_STRETCH(btn_row)
    qt.LAYOUT_ADD_LAYOUT(layout, btn_row)

    qt.LAYOUT_ADD_SPACING(layout, 10)
    local privacy_row = qt.CREATE_LAYOUT("horizontal")
    local privacy_combo = qt.CREATE_COMBOBOX({"Unlisted", "Private", "Public"})
    qt.SET_CURRENT_INDEX(privacy_combo, 0)
    qt.LAYOUT_ADD_WIDGET(privacy_row, qt.CREATE_LABEL("Default video privacy:"))
    qt.LAYOUT_ADD_WIDGET(privacy_row, privacy_combo)
    qt.LAYOUT_ADD_STRETCH(privacy_row)
    qt.LAYOUT_ADD_LAYOUT(layout, privacy_row)

    qt.SET_WIDGET_LAYOUT(group, layout)
    return group, status, configure_btn, auth_btn, logout_btn, privacy_combo
end

-- Build the GitHub integration group: status + repo fields + token button +
-- default labels.
local function build_github_section()
    local group = qt.CREATE_GROUP_BOX("GitHub Integration")
    local layout = qt.CREATE_LAYOUT("vertical")

    local status = qt.CREATE_LABEL("Status: Not configured")
    qt.SET_WIDGET_STYLE(status, "color: red;")
    qt.LAYOUT_ADD_WIDGET(layout, status)

    github_issue_creator.load_token()
    if github_issue_creator.search_issues("test") then
        qt.SET_TEXT(status, "Status: Authenticated ✓")
        qt.SET_WIDGET_STYLE(status, "color: green;")
    end

    qt.LAYOUT_ADD_SPACING(layout, 5)

    local repo_row = qt.CREATE_LAYOUT("horizontal")
    local repo_owner = qt.CREATE_LINE_EDIT("Owner")
    local repo_name  = qt.CREATE_LINE_EDIT("Repository")
    qt.LAYOUT_ADD_WIDGET(repo_row, qt.CREATE_LABEL("Repository:"))
    qt.LAYOUT_ADD_WIDGET(repo_row, repo_owner)
    qt.LAYOUT_ADD_WIDGET(repo_row, qt.CREATE_LABEL("/"))
    qt.LAYOUT_ADD_WIDGET(repo_row, repo_name)
    qt.LAYOUT_ADD_STRETCH(repo_row)
    qt.LAYOUT_ADD_LAYOUT(layout, repo_row)

    qt.LAYOUT_ADD_SPACING(layout, 5)
    local token_btn = qt.CREATE_BUTTON("Set Personal Access Token...")
    qt.LAYOUT_ADD_WIDGET(layout, token_btn)

    local help = qt.CREATE_LABEL(
        "Create a token at: github.com/settings/tokens (with 'repo' scope)")
    qt.SET_WIDGET_STYLE(help, "color: gray; font-size: 10pt;")
    qt.LAYOUT_ADD_WIDGET(layout, help)

    qt.LAYOUT_ADD_SPACING(layout, 10)
    local labels_row = qt.CREATE_LAYOUT("horizontal")
    local labels_edit = qt.CREATE_LINE_EDIT("bug, auto-reported")
    qt.LAYOUT_ADD_WIDGET(labels_row, qt.CREATE_LABEL("Default labels:"))
    qt.LAYOUT_ADD_WIDGET(labels_row, labels_edit)
    qt.LAYOUT_ADD_LAYOUT(layout, labels_row)

    qt.SET_WIDGET_LAYOUT(group, layout)
    return group, status, repo_owner, repo_name, token_btn, labels_edit
end

-- Build the "Bug Submission" group: three checkboxes for upload / issue /
-- review-dialog defaults.
local function build_submission_section()
    local group = qt.CREATE_GROUP_BOX("Bug Submission")
    local layout = qt.CREATE_LAYOUT("vertical")

    local function checkbox(label)
        local cb = qt.CREATE_CHECKBOX(label)
        qt.SET_CHECKED(cb, true)
        qt.LAYOUT_ADD_WIDGET(layout, cb)
        return cb
    end

    local auto_upload = checkbox("Automatically upload video to YouTube")
    local auto_issue  = checkbox("Automatically create GitHub issue")
    local review      = checkbox("Show review dialog before submission")

    qt.SET_WIDGET_LAYOUT(group, layout)
    return group, auto_upload, auto_issue, review
end

-- Build the bottom button row: Test / Save / Cancel, right-aligned.
local function build_bottom_buttons()
    local row = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(row)
    local test_btn   = qt.CREATE_BUTTON("Test Configuration")
    local save_btn   = qt.CREATE_BUTTON("Save Settings")
    local cancel_btn = qt.CREATE_BUTTON("Cancel")
    qt.LAYOUT_ADD_WIDGET(row, test_btn)
    qt.LAYOUT_ADD_WIDGET(row, save_btn)
    qt.LAYOUT_ADD_WIDGET(row, cancel_btn)
    return row, test_btn, save_btn, cancel_btn
end

function PreferencesPanel.create()
    if not qt.is_available() then
        log.error("Qt bindings not available for preferences panel")
        return nil
    end

    local main_layout = qt.CREATE_LAYOUT("vertical")
    if not main_layout then
        log.error("Failed to create preferences panel layout")
        return nil
    end

    qt.LAYOUT_ADD_WIDGET(main_layout, qt.CREATE_LABEL("Bug Reporter Settings"))
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    local capture_group, enable_capture, buffer_gestures = build_capture_section()
    qt.LAYOUT_ADD_WIDGET(main_layout, capture_group)
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    local youtube_group, youtube_status, youtube_configure, youtube_auth,
          youtube_logout, privacy_combo = build_youtube_section()
    qt.LAYOUT_ADD_WIDGET(main_layout, youtube_group)
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    local github_group, github_status, repo_owner, repo_name, github_token,
          labels_edit = build_github_section()
    qt.LAYOUT_ADD_WIDGET(main_layout, github_group)
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    local submission_group, auto_upload, auto_issue, review_dialog = build_submission_section()
    qt.LAYOUT_ADD_WIDGET(main_layout, submission_group)

    qt.LAYOUT_ADD_SPACING(main_layout, 20)
    local bottom_row, test_config, save, cancel = build_bottom_buttons()
    qt.LAYOUT_ADD_LAYOUT(main_layout, bottom_row)

    local container = qt.CREATE_WIDGET()
    if not container then
        log.error("Failed to create preferences panel container widget")
        return nil
    end
    qt.SET_WIDGET_LAYOUT(container, main_layout)

    return {
        widget = container,
        widgets = {
            enable_capture    = enable_capture,
            buffer_gestures   = buffer_gestures,
            youtube_status    = youtube_status,
            github_status     = github_status,
            repo_owner        = repo_owner,
            repo_name         = repo_name,
            privacy_combo     = privacy_combo,
            labels_edit       = labels_edit,
            auto_upload       = auto_upload,
            auto_issue        = auto_issue,
            review_dialog     = review_dialog,
            youtube_configure = youtube_configure,
            youtube_auth      = youtube_auth,
            youtube_logout    = youtube_logout,
            github_token      = github_token,
            test_config       = test_config,
            save              = save,
            cancel            = cancel,
        }
    }
end

-- Save preferences to file
-- @param preferences: Table of preference values
function PreferencesPanel.save_preferences(preferences)
    local dkjson = require("dkjson")
    local prefs_file = os.getenv("HOME") .. "/.jve_bug_reporter_prefs.json"

    local json = dkjson.encode(preferences, {indent = true})

    -- Use secure file write to prevent race condition
    local success = utils.write_secure_file(prefs_file, json)
    return success
end

-- Load preferences from file
-- @return: Preferences table or defaults
function PreferencesPanel.load_preferences()
    local dkjson = require("dkjson")
    local prefs_file = os.getenv("HOME") .. "/.jve_bug_reporter_prefs.json"

    local file = io.open(prefs_file, "r")
    if not file then
        -- Return defaults
        return {
            enable_capture = true,
            buffer_gestures = 200,
            video_privacy = "unlisted",
            auto_upload_video = true,
            auto_create_issue = true,
            show_review_dialog = true,
            github_owner = "",
            github_repo = "",
            github_labels = "bug, auto-reported"
        }
    end

    local content = file:read("*a")
    file:close()

    local prefs = dkjson.decode(content)
    return prefs or {}
end

return PreferencesPanel
