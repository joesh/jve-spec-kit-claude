-- oauth_dialogs.lua
-- OAuth configuration dialogs for YouTube and GitHub

local youtube_oauth = require("bug_reporter.youtube_oauth")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local logger = require("core.logger")

local OAuthDialogs = {}

-- === YouTube OAuth Dialogs ===

-- Show YouTube credentials configuration dialog
-- @return: Dialog widget
function OAuthDialogs.show_youtube_credentials_dialog()
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        return nil
    end

    local dialog = CREATE_DIALOG("Configure YouTube OAuth Credentials")
    if not dialog then
        logger.error("bug_reporter", "Failed to create YouTube credentials dialog")
        return nil
    end

    local layout = CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create YouTube credentials layout")
        return nil
    end

    -- Instructions
    local instructions = CREATE_LABEL(
        "To upload videos to YouTube, you need to create OAuth 2.0 credentials:\n\n" ..
        "1. Visit: https://console.cloud.google.com/apis/credentials\n" ..
        "2. Create a new project (or select existing)\n" ..
        "3. Enable YouTube Data API v3\n" ..
        "4. Create OAuth 2.0 Client ID (Desktop app)\n" ..
        "5. Copy the Client ID and Client Secret below"
    )
    SET_WIDGET_PROPERTY(instructions, "wordWrap", true)
    LAYOUT_ADD_WIDGET(layout, instructions)

    LAYOUT_ADD_SPACING(layout, 15)

    -- Client ID
    local client_id_label = CREATE_LABEL("Client ID:")
    SET_WIDGET_STYLE(client_id_label, "font-weight: bold;")
    LAYOUT_ADD_WIDGET(layout, client_id_label)

    local client_id_edit = CREATE_LINE_EDIT("")
    SET_WIDGET_PROPERTY(client_id_edit, "placeholderText", "YOUR_CLIENT_ID.apps.googleusercontent.com")
    LAYOUT_ADD_WIDGET(layout, client_id_edit)

    LAYOUT_ADD_SPACING(layout, 10)

    -- Client Secret
    local client_secret_label = CREATE_LABEL("Client Secret:")
    SET_WIDGET_STYLE(client_secret_label, "font-weight: bold;")
    LAYOUT_ADD_WIDGET(layout, client_secret_label)

    local client_secret_edit = CREATE_LINE_EDIT("")
    SET_WIDGET_PROPERTY(client_secret_edit, "placeholderText", "YOUR_CLIENT_SECRET")
    SET_WIDGET_PROPERTY(client_secret_edit, "echoMode", "Password")  -- Hide secret
    LAYOUT_ADD_WIDGET(layout, client_secret_edit)

    LAYOUT_ADD_SPACING(layout, 10)

    local show_secret_checkbox = CREATE_CHECKBOX("Show Client Secret")
    LAYOUT_ADD_WIDGET(layout, show_secret_checkbox)

    -- Buttons
    LAYOUT_ADD_SPACING(layout, 20)
    local button_layout = CREATE_LAYOUT("horizontal")
    LAYOUT_ADD_STRETCH(button_layout)

    local save_button = CREATE_BUTTON("Save Credentials")
    local cancel_button = CREATE_BUTTON("Cancel")

    LAYOUT_ADD_WIDGET(button_layout, save_button)
    LAYOUT_ADD_WIDGET(button_layout, cancel_button)
    LAYOUT_ADD_LAYOUT(layout, button_layout)

    SET_DIALOG_LAYOUT(dialog, layout)

    dialog.widgets = {
        client_id = client_id_edit,
        client_secret = client_secret_edit,
        show_secret = show_secret_checkbox,
        save = save_button,
        cancel = cancel_button
    }

    return dialog
end

-- Show YouTube authorization dialog
-- @return: Dialog widget
function OAuthDialogs.show_youtube_auth_dialog()
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        return nil
    end

    local dialog = CREATE_DIALOG("Authorize YouTube Access")
    if not dialog then
        logger.error("bug_reporter", "Failed to create YouTube auth dialog")
        return nil
    end

    local layout = CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create YouTube auth layout")
        return nil
    end

    -- Generate authorization URL
    local auth_url = youtube_oauth.get_authorization_url()
    if not auth_url then
        local error_label = CREATE_LABEL("Error: OAuth credentials not configured.\nPlease configure credentials first.")
        SET_WIDGET_STYLE(error_label, "color: red;")
        LAYOUT_ADD_WIDGET(layout, error_label)

        local ok_button = CREATE_BUTTON("OK")
        LAYOUT_ADD_WIDGET(layout, ok_button)

        SET_DIALOG_LAYOUT(dialog, layout)
        return dialog
    end

    -- Instructions
    local instructions = CREATE_LABEL(
        "To authorize JVE to upload videos to your YouTube account:\n\n" ..
        "1. Click 'Open Authorization URL' below\n" ..
        "2. Sign in to your Google account\n" ..
        "3. Grant JVE permission to upload videos\n" ..
        "4. You'll be redirected to localhost - this is normal\n" ..
        "5. Wait for JVE to receive the authorization code"
    )
    SET_WIDGET_PROPERTY(instructions, "wordWrap", true)
    LAYOUT_ADD_WIDGET(layout, instructions)

    LAYOUT_ADD_SPACING(layout, 15)

    -- Authorization URL
    local url_label = CREATE_LABEL("Authorization URL:")
    SET_WIDGET_STYLE(url_label, "font-weight: bold;")
    LAYOUT_ADD_WIDGET(layout, url_label)

    local url_edit = CREATE_LINE_EDIT(auth_url)
    SET_WIDGET_PROPERTY(url_edit, "readOnly", true)
    LAYOUT_ADD_WIDGET(layout, url_edit)

    LAYOUT_ADD_SPACING(layout, 10)

    -- Status
    local status_label = CREATE_LABEL("Status: Waiting for authorization...")
    LAYOUT_ADD_WIDGET(layout, status_label)

    -- Buttons
    LAYOUT_ADD_SPACING(layout, 20)
    local button_layout = CREATE_LAYOUT("horizontal")
    LAYOUT_ADD_STRETCH(button_layout)

    local open_url_button = CREATE_BUTTON("Open Authorization URL")
    local cancel_button = CREATE_BUTTON("Cancel")

    LAYOUT_ADD_WIDGET(button_layout, open_url_button)
    LAYOUT_ADD_WIDGET(button_layout, cancel_button)
    LAYOUT_ADD_LAYOUT(layout, button_layout)

    SET_DIALOG_LAYOUT(dialog, layout)

    dialog.auth_url = auth_url
    dialog.widgets = {
        url_edit = url_edit,
        status = status_label,
        open_url = open_url_button,
        cancel = cancel_button
    }

    return dialog
end

-- === GitHub OAuth Dialogs ===

-- Show GitHub token configuration dialog
-- @return: Dialog widget
function OAuthDialogs.show_github_token_dialog()
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        return nil
    end

    local dialog = CREATE_DIALOG("Configure GitHub Personal Access Token")
    if not dialog then
        logger.error("bug_reporter", "Failed to create GitHub token dialog")
        return nil
    end

    local layout = CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create GitHub token layout")
        return nil
    end

    -- Instructions
    local instructions = CREATE_LABEL(
        "To create GitHub issues automatically, you need a Personal Access Token:\n\n" ..
        "1. Visit: https://github.com/settings/tokens\n" ..
        "2. Click 'Generate new token (classic)'\n" ..
        "3. Give it a descriptive name (e.g., 'JVE Bug Reporter')\n" ..
        "4. Select scope: 'repo' (Full control of private repositories)\n" ..
        "5. Click 'Generate token' at the bottom\n" ..
        "6. Copy the token (it's only shown once!)\n" ..
        "7. Paste it below"
    )
    SET_WIDGET_PROPERTY(instructions, "wordWrap", true)
    LAYOUT_ADD_WIDGET(layout, instructions)

    LAYOUT_ADD_SPACING(layout, 15)

    -- Token input
    local token_label = CREATE_LABEL("Personal Access Token:")
    SET_WIDGET_STYLE(token_label, "font-weight: bold;")
    LAYOUT_ADD_WIDGET(layout, token_label)

    local token_edit = CREATE_LINE_EDIT("")
    SET_WIDGET_PROPERTY(token_edit, "placeholderText", "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    SET_WIDGET_PROPERTY(token_edit, "echoMode", "Password")
    LAYOUT_ADD_WIDGET(layout, token_edit)

    LAYOUT_ADD_SPACING(layout, 10)

    local show_token_checkbox = CREATE_CHECKBOX("Show Token")
    LAYOUT_ADD_WIDGET(layout, show_token_checkbox)

    LAYOUT_ADD_SPACING(layout, 15)

    -- Repository configuration
    local repo_label = CREATE_LABEL("Repository:")
    SET_WIDGET_STYLE(repo_label, "font-weight: bold;")
    LAYOUT_ADD_WIDGET(layout, repo_label)

    local repo_layout = CREATE_LAYOUT("horizontal")
    local owner_edit = CREATE_LINE_EDIT("")
    SET_WIDGET_PROPERTY(owner_edit, "placeholderText", "owner")
    local slash_label = CREATE_LABEL("/")
    local repo_edit = CREATE_LINE_EDIT("")
    SET_WIDGET_PROPERTY(repo_edit, "placeholderText", "repository")

    LAYOUT_ADD_WIDGET(repo_layout, owner_edit)
    LAYOUT_ADD_WIDGET(repo_layout, slash_label)
    LAYOUT_ADD_WIDGET(repo_layout, repo_edit)
    LAYOUT_ADD_LAYOUT(layout, repo_layout)

    -- Buttons
    LAYOUT_ADD_SPACING(layout, 20)
    local button_layout = CREATE_LAYOUT("horizontal")
    LAYOUT_ADD_STRETCH(button_layout)

    local test_button = CREATE_BUTTON("Test Connection")
    local save_button = CREATE_BUTTON("Save Settings")
    local cancel_button = CREATE_BUTTON("Cancel")

    LAYOUT_ADD_WIDGET(button_layout, test_button)
    LAYOUT_ADD_WIDGET(button_layout, save_button)
    LAYOUT_ADD_WIDGET(button_layout, cancel_button)
    LAYOUT_ADD_LAYOUT(layout, button_layout)

    SET_DIALOG_LAYOUT(dialog, layout)

    dialog.widgets = {
        token = token_edit,
        show_token = show_token_checkbox,
        owner = owner_edit,
        repo = repo_edit,
        test = test_button,
        save = save_button,
        cancel = cancel_button
    }

    return dialog
end

-- Show connection test result
-- @param success: Boolean - whether test succeeded
-- @param message: Result message
function OAuthDialogs.show_connection_test_result(success, message)
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        return nil
    end

    local dialog = CREATE_DIALOG("Connection Test")
    if not dialog then
        logger.error("bug_reporter", "Failed to create connection test dialog")
        return nil
    end

    local layout = CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create connection test layout")
        return nil
    end

    local result_label
    if success then
        result_label = CREATE_LABEL("✓ Connection Successful")
        SET_WIDGET_STYLE(result_label, "color: green; font-size: 14pt; font-weight: bold;")
    else
        result_label = CREATE_LABEL("✗ Connection Failed")
        SET_WIDGET_STYLE(result_label, "color: red; font-size: 14pt; font-weight: bold;")
    end
    LAYOUT_ADD_WIDGET(layout, result_label)

    LAYOUT_ADD_SPACING(layout, 10)

    local message_label = CREATE_LABEL(message)
    SET_WIDGET_PROPERTY(message_label, "wordWrap", true)
    LAYOUT_ADD_WIDGET(layout, message_label)

    LAYOUT_ADD_SPACING(layout, 20)

    local button_layout = CREATE_LAYOUT("horizontal")
    LAYOUT_ADD_STRETCH(button_layout)
    local ok_button = CREATE_BUTTON("OK")
    LAYOUT_ADD_WIDGET(button_layout, ok_button)
    LAYOUT_ADD_LAYOUT(layout, button_layout)

    SET_DIALOG_LAYOUT(dialog, layout)

    return dialog
end

-- Show authorization success/failure
-- @param success: Boolean
-- @param message: Result message
function OAuthDialogs.show_auth_result(success, message)
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        return nil
    end

    local dialog = CREATE_DIALOG("Authorization Result")
    if not dialog then
        logger.error("bug_reporter", "Failed to create auth result dialog")
        return nil
    end

    local layout = CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create auth result layout")
        return nil
    end

    local result_label
    if success then
        result_label = CREATE_LABEL("✓ Authorization Successful")
        SET_WIDGET_STYLE(result_label, "color: green; font-size: 14pt; font-weight: bold;")
    else
        result_label = CREATE_LABEL("✗ Authorization Failed")
        SET_WIDGET_STYLE(result_label, "color: red; font-size: 14pt; font-weight: bold;")
    end
    LAYOUT_ADD_WIDGET(layout, result_label)

    LAYOUT_ADD_SPACING(layout, 10)

    local message_label = CREATE_LABEL(message)
    SET_WIDGET_PROPERTY(message_label, "wordWrap", true)
    LAYOUT_ADD_WIDGET(layout, message_label)

    LAYOUT_ADD_SPACING(layout, 20)

    local button_layout = CREATE_LAYOUT("horizontal")
    LAYOUT_ADD_STRETCH(button_layout)
    local ok_button = CREATE_BUTTON("OK")
    LAYOUT_ADD_WIDGET(button_layout, ok_button)
    LAYOUT_ADD_LAYOUT(layout, button_layout)

    SET_DIALOG_LAYOUT(dialog, layout)

    return dialog
end

return OAuthDialogs
