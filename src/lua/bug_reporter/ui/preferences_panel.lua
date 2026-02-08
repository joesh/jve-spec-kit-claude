--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~194 LOC
-- Volatility: unknown
--
-- @file preferences_panel.lua
-- Original intent (unreviewed):
-- preferences_panel.lua
-- Bug reporter preferences UI panel (pure Lua + Qt bindings)
local youtube_oauth = require("bug_reporter.youtube_oauth")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local bug_submission = require("bug_reporter.bug_submission")
local utils = require("bug_reporter.utils")
local logger = require("core.logger")
local qt = require("bug_reporter.qt_compat")

local PreferencesPanel = {}

-- Create preferences panel widget
-- @return: QWidget containing preferences UI
function PreferencesPanel.create()
    -- Check if Qt bindings are available
    if not qt.is_available() then
        logger.error("bug_reporter", "Qt bindings not available for preferences panel")
        return nil
    end

    -- Main layout
    local main_layout = qt.CREATE_LAYOUT("vertical")
    if not main_layout then
        logger.error("bug_reporter", "Failed to create preferences panel layout")
        return nil
    end

    -- Title
    local title_label = qt.CREATE_LABEL("Bug Reporter Settings")
    qt.LAYOUT_ADD_WIDGET(main_layout, title_label)

    -- Separator
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Capture Settings ===
    local capture_group = qt.CREATE_GROUP_BOX("Automatic Capture")
    local capture_layout = qt.CREATE_LAYOUT("vertical")

    local enable_capture_checkbox = qt.CREATE_CHECKBOX("Enable automatic gesture and screenshot capture")
    qt.SET_CHECKED(enable_capture_checkbox, true)  -- Default enabled
    qt.LAYOUT_ADD_WIDGET(capture_layout, enable_capture_checkbox)

    local capture_desc = qt.CREATE_LABEL("Continuously captures gestures and screenshots for bug reporting")
    qt.SET_WIDGET_STYLE(capture_desc, "color: gray; font-size: 10pt;")
    qt.LAYOUT_ADD_WIDGET(capture_layout, capture_desc)

    qt.LAYOUT_ADD_SPACING(capture_layout, 5)

    -- Ring buffer settings (spinbox not implemented, use line edit)
    local buffer_settings_layout = qt.CREATE_LAYOUT("horizontal")
    local buffer_label = qt.CREATE_LABEL("Ring buffer size:")
    local buffer_gestures = qt.CREATE_LINE_EDIT("200")  -- Spinbox fallback
    local buffer_unit = qt.CREATE_LABEL("gestures")
    qt.LAYOUT_ADD_WIDGET(buffer_settings_layout, buffer_label)
    qt.LAYOUT_ADD_WIDGET(buffer_settings_layout, buffer_gestures)
    qt.LAYOUT_ADD_WIDGET(buffer_settings_layout, buffer_unit)
    qt.LAYOUT_ADD_STRETCH(buffer_settings_layout)
    qt.LAYOUT_ADD_LAYOUT(capture_layout, buffer_settings_layout)

    qt.SET_WIDGET_LAYOUT(capture_group, capture_layout)
    qt.LAYOUT_ADD_WIDGET(main_layout, capture_group)

    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    -- === YouTube Settings ===
    local youtube_group = qt.CREATE_GROUP_BOX("YouTube Integration")
    local youtube_layout = qt.CREATE_LAYOUT("vertical")

    -- Status
    local youtube_status = qt.CREATE_LABEL("Status: Not configured")
    qt.SET_WIDGET_STYLE(youtube_status, "color: red;")
    qt.LAYOUT_ADD_WIDGET(youtube_layout, youtube_status)

    -- Update status
    if youtube_oauth.is_authenticated() then
        qt.SET_TEXT(youtube_status, "Status: Authenticated ✓")
        qt.SET_WIDGET_STYLE(youtube_status, "color: green;")
    end

    qt.LAYOUT_ADD_SPACING(youtube_layout, 5)

    -- Buttons
    local youtube_buttons_layout = qt.CREATE_LAYOUT("horizontal")
    local youtube_configure_button = qt.CREATE_BUTTON("Configure Credentials...")
    local youtube_auth_button = qt.CREATE_BUTTON("Authorize YouTube")
    local youtube_logout_button = qt.CREATE_BUTTON("Logout")

    qt.LAYOUT_ADD_WIDGET(youtube_buttons_layout, youtube_configure_button)
    qt.LAYOUT_ADD_WIDGET(youtube_buttons_layout, youtube_auth_button)
    qt.LAYOUT_ADD_WIDGET(youtube_buttons_layout, youtube_logout_button)
    qt.LAYOUT_ADD_STRETCH(youtube_buttons_layout)
    qt.LAYOUT_ADD_LAYOUT(youtube_layout, youtube_buttons_layout)

    -- Privacy setting
    qt.LAYOUT_ADD_SPACING(youtube_layout, 10)
    local privacy_layout = qt.CREATE_LAYOUT("horizontal")
    local privacy_label = qt.CREATE_LABEL("Default video privacy:")
    local privacy_combo = qt.CREATE_COMBOBOX({"Unlisted", "Private", "Public"})
    qt.SET_CURRENT_INDEX(privacy_combo, 0)  -- Default to Unlisted
    qt.LAYOUT_ADD_WIDGET(privacy_layout, privacy_label)
    qt.LAYOUT_ADD_WIDGET(privacy_layout, privacy_combo)
    qt.LAYOUT_ADD_STRETCH(privacy_layout)
    qt.LAYOUT_ADD_LAYOUT(youtube_layout, privacy_layout)

    qt.SET_WIDGET_LAYOUT(youtube_group, youtube_layout)
    qt.LAYOUT_ADD_WIDGET(main_layout, youtube_group)

    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    -- === GitHub Settings ===
    local github_group = qt.CREATE_GROUP_BOX("GitHub Integration")
    local github_layout = qt.CREATE_LAYOUT("vertical")

    -- Status
    local github_status = qt.CREATE_LABEL("Status: Not configured")
    qt.SET_WIDGET_STYLE(github_status, "color: red;")
    qt.LAYOUT_ADD_WIDGET(github_layout, github_status)

    -- Check GitHub status
    github_issue_creator.load_token()
    local test_result = github_issue_creator.search_issues("test")
    if test_result then
        qt.SET_TEXT(github_status, "Status: Authenticated ✓")
        qt.SET_WIDGET_STYLE(github_status, "color: green;")
    end

    qt.LAYOUT_ADD_SPACING(github_layout, 5)

    -- Repository
    local repo_layout = qt.CREATE_LAYOUT("horizontal")
    local repo_label = qt.CREATE_LABEL("Repository:")
    local repo_owner = qt.CREATE_LINE_EDIT("Owner")
    local repo_slash = qt.CREATE_LABEL("/")
    local repo_name = qt.CREATE_LINE_EDIT("Repository")
    qt.LAYOUT_ADD_WIDGET(repo_layout, repo_label)
    qt.LAYOUT_ADD_WIDGET(repo_layout, repo_owner)
    qt.LAYOUT_ADD_WIDGET(repo_layout, repo_slash)
    qt.LAYOUT_ADD_WIDGET(repo_layout, repo_name)
    qt.LAYOUT_ADD_STRETCH(repo_layout)
    qt.LAYOUT_ADD_LAYOUT(github_layout, repo_layout)

    qt.LAYOUT_ADD_SPACING(github_layout, 5)

    -- Token button
    local github_token_button = qt.CREATE_BUTTON("Set Personal Access Token...")
    qt.LAYOUT_ADD_WIDGET(github_layout, github_token_button)

    -- Help text
    local github_help = qt.CREATE_LABEL(
        "Create a token at: github.com/settings/tokens (with 'repo' scope)"
    )
    qt.SET_WIDGET_STYLE(github_help, "color: gray; font-size: 10pt;")
    qt.LAYOUT_ADD_WIDGET(github_layout, github_help)

    -- Default labels
    qt.LAYOUT_ADD_SPACING(github_layout, 10)
    local labels_layout = qt.CREATE_LAYOUT("horizontal")
    local labels_label = qt.CREATE_LABEL("Default labels:")
    local labels_edit = qt.CREATE_LINE_EDIT("bug, auto-reported")
    qt.LAYOUT_ADD_WIDGET(labels_layout, labels_label)
    qt.LAYOUT_ADD_WIDGET(labels_layout, labels_edit)
    qt.LAYOUT_ADD_LAYOUT(github_layout, labels_layout)

    qt.SET_WIDGET_LAYOUT(github_group, github_layout)
    qt.LAYOUT_ADD_WIDGET(main_layout, github_group)

    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Submission Settings ===
    local submission_group = qt.CREATE_GROUP_BOX("Bug Submission")
    local submission_layout = qt.CREATE_LAYOUT("vertical")

    local auto_upload_checkbox = qt.CREATE_CHECKBOX("Automatically upload video to YouTube")
    qt.SET_CHECKED(auto_upload_checkbox, true)
    qt.LAYOUT_ADD_WIDGET(submission_layout, auto_upload_checkbox)

    local auto_issue_checkbox = qt.CREATE_CHECKBOX("Automatically create GitHub issue")
    qt.SET_CHECKED(auto_issue_checkbox, true)
    qt.LAYOUT_ADD_WIDGET(submission_layout, auto_issue_checkbox)

    local review_checkbox = qt.CREATE_CHECKBOX("Show review dialog before submission")
    qt.SET_CHECKED(review_checkbox, true)
    qt.LAYOUT_ADD_WIDGET(submission_layout, review_checkbox)

    qt.SET_WIDGET_LAYOUT(submission_group, submission_layout)
    qt.LAYOUT_ADD_WIDGET(main_layout, submission_group)

    -- Bottom buttons
    qt.LAYOUT_ADD_SPACING(main_layout, 20)
    local bottom_layout = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(bottom_layout)

    local test_button = qt.CREATE_BUTTON("Test Configuration")
    local save_button = qt.CREATE_BUTTON("Save Settings")
    local cancel_button = qt.CREATE_BUTTON("Cancel")

    qt.LAYOUT_ADD_WIDGET(bottom_layout, test_button)
    qt.LAYOUT_ADD_WIDGET(bottom_layout, save_button)
    qt.LAYOUT_ADD_WIDGET(bottom_layout, cancel_button)
    qt.LAYOUT_ADD_LAYOUT(main_layout, bottom_layout)

    -- Create container widget
    local container = qt.CREATE_WIDGET()
    if not container then
        logger.error("bug_reporter", "Failed to create preferences panel container widget")
        return nil
    end

    qt.SET_WIDGET_LAYOUT(container, main_layout)

    -- Return wrapper table (container is C++ userdata)
    return {
        widget = container,
        widgets = {
            enable_capture = enable_capture_checkbox,
            buffer_gestures = buffer_gestures,
            youtube_status = youtube_status,
            github_status = github_status,
            repo_owner = repo_owner,
            repo_name = repo_name,
            privacy_combo = privacy_combo,
            labels_edit = labels_edit,
            auto_upload = auto_upload_checkbox,
            auto_issue = auto_issue_checkbox,
            review_dialog = review_checkbox,
            youtube_configure = youtube_configure_button,
            youtube_auth = youtube_auth_button,
            youtube_logout = youtube_logout_button,
            github_token = github_token_button,
            test_config = test_button,
            save = save_button,
            cancel = cancel_button
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
    local success, err = utils.write_secure_file(prefs_file, json)
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
