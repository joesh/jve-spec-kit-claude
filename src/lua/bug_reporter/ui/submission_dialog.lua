-- submission_dialog.lua
-- Bug submission review dialog (shows before uploading)

local json_test_loader = require("bug_reporter.json_test_loader")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local logger = require("core.logger")

local SubmissionDialog = {}

-- Create bug submission review dialog
-- @param test_path: Path to test JSON file
-- @return: Dialog widget
function SubmissionDialog.create(test_path)
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        logger.error("bug_reporter", "Qt bindings not available for submission dialog")
        return nil
    end

    -- Load test data
    local test, err = json_test_loader.load(test_path)
    if not test then
        logger.error("bug_reporter", "Failed to load test: " .. err)
        return nil
    end

    -- Create dialog
    local dialog = CREATE_DIALOG("Submit Bug Report")
    if not dialog then
        logger.error("bug_reporter", "Failed to create submission dialog")
        return nil
    end

    local main_layout = CREATE_LAYOUT("vertical")
    if not main_layout then
        logger.error("bug_reporter", "Failed to create submission dialog layout")
        return nil
    end

    -- === Header ===
    local header_label = CREATE_LABEL("Review Bug Report Before Submission")
    SET_WIDGET_STYLE(header_label, "font-size: 14pt; font-weight: bold;")
    LAYOUT_ADD_WIDGET(main_layout, header_label)

    LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Test Information ===
    local info_group = CREATE_GROUP_BOX("Bug Information")
    local info_layout = CREATE_LAYOUT("vertical")

    -- Test name
    local name_layout = CREATE_LAYOUT("horizontal")
    local name_label = CREATE_LABEL("Name:")
    SET_WIDGET_STYLE(name_label, "font-weight: bold; min-width: 100px;")
    local name_value = CREATE_LABEL(test.test_name or test.test_id)
    LAYOUT_ADD_WIDGET(name_layout, name_label)
    LAYOUT_ADD_WIDGET(name_layout, name_value)
    LAYOUT_ADD_STRETCH(name_layout)
    LAYOUT_ADD_LAYOUT(info_layout, name_layout)

    -- Category
    local category_layout = CREATE_LAYOUT("horizontal")
    local category_label = CREATE_LABEL("Category:")
    SET_WIDGET_STYLE(category_label, "font-weight: bold; min-width: 100px;")
    local category_value = CREATE_LABEL(test.category or "bug")
    LAYOUT_ADD_WIDGET(category_layout, category_label)
    LAYOUT_ADD_WIDGET(category_layout, category_value)
    LAYOUT_ADD_STRETCH(category_layout)
    LAYOUT_ADD_LAYOUT(info_layout, category_layout)

    -- Timestamp
    if test.capture_metadata and test.capture_metadata.timestamp then
        local time_layout = CREATE_LAYOUT("horizontal")
        local time_label = CREATE_LABEL("Captured:")
        SET_WIDGET_STYLE(time_label, "font-weight: bold; min-width: 100px;")
        local time_value = CREATE_LABEL(
            os.date("%Y-%m-%d %H:%M:%S", test.capture_metadata.timestamp)
        )
        LAYOUT_ADD_WIDGET(time_layout, time_label)
        LAYOUT_ADD_WIDGET(time_layout, time_value)
        LAYOUT_ADD_STRETCH(time_layout)
        LAYOUT_ADD_LAYOUT(info_layout, time_layout)
    end

    -- Statistics
    local stats_layout = CREATE_LAYOUT("horizontal")
    local stats_label = CREATE_LABEL("Statistics:")
    SET_WIDGET_STYLE(stats_label, "font-weight: bold; min-width: 100px;")
    local stats_text = string.format(
        "%d gestures, %d commands, %d screenshots",
        #(test.gesture_log or {}),
        #(test.command_log or {}),
        (test.screenshots and test.screenshots.screenshot_count or 0)
    )
    local stats_value = CREATE_LABEL(stats_text)
    LAYOUT_ADD_WIDGET(stats_layout, stats_label)
    LAYOUT_ADD_WIDGET(stats_layout, stats_value)
    LAYOUT_ADD_STRETCH(stats_layout)
    LAYOUT_ADD_LAYOUT(info_layout, stats_layout)

    SET_WIDGET_LAYOUT(info_group, info_layout)
    LAYOUT_ADD_WIDGET(main_layout, info_group)

    LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Preview ===
    local preview_group = CREATE_GROUP_BOX("GitHub Issue Preview")
    local preview_layout = CREATE_LAYOUT("vertical")

    -- Issue title
    local title_layout = CREATE_LAYOUT("horizontal")
    local title_label = CREATE_LABEL("Title:")
    SET_WIDGET_STYLE(title_label, "font-weight: bold;")
    LAYOUT_ADD_WIDGET(title_layout, title_label)
    LAYOUT_ADD_LAYOUT(preview_layout, title_layout)

    local issue_title = require("bug_reporter.bug_submission").format_issue_title(test)
    local title_edit = CREATE_LINE_EDIT(issue_title)
    LAYOUT_ADD_WIDGET(preview_layout, title_edit)

    LAYOUT_ADD_SPACING(preview_layout, 5)

    -- Issue body
    local body_label = CREATE_LABEL("Body:")
    SET_WIDGET_STYLE(body_label, "font-weight: bold;")
    LAYOUT_ADD_WIDGET(preview_layout, body_label)

    local issue_body = github_issue_creator.format_bug_report_body(test)
    local body_text = CREATE_TEXT_EDIT(issue_body)
    SET_WIDGET_PROPERTY(body_text, "readOnly", true)
    SET_WIDGET_PROPERTY(body_text, "minimumHeight", 200)
    LAYOUT_ADD_WIDGET(preview_layout, body_text)

    SET_WIDGET_LAYOUT(preview_group, preview_layout)
    LAYOUT_ADD_WIDGET(main_layout, preview_group)

    LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Options ===
    local options_group = CREATE_GROUP_BOX("Submission Options")
    local options_layout = CREATE_LAYOUT("vertical")

    local upload_video_checkbox = CREATE_CHECKBOX("Upload slideshow video to YouTube")
    SET_CHECKED(upload_video_checkbox, true)
    LAYOUT_ADD_WIDGET(options_layout, upload_video_checkbox)

    -- Check if video exists
    local video_path = SubmissionDialog.find_slideshow_video(test_path)
    if not video_path then
        SET_ENABLED(upload_video_checkbox, false)
        local no_video_label = CREATE_LABEL("  (No slideshow video found)")
        SET_WIDGET_STYLE(no_video_label, "color: red;")
        LAYOUT_ADD_WIDGET(options_layout, no_video_label)
    else
        local video_info = CREATE_LABEL("  Video: " .. video_path)
        SET_WIDGET_STYLE(video_info, "color: gray; font-size: 9pt;")
        LAYOUT_ADD_WIDGET(options_layout, video_info)
    end

    local create_issue_checkbox = CREATE_CHECKBOX("Create GitHub issue")
    SET_CHECKED(create_issue_checkbox, true)
    LAYOUT_ADD_WIDGET(options_layout, create_issue_checkbox)

    local privacy_layout = CREATE_LAYOUT("horizontal")
    local privacy_label = CREATE_LABEL("  Video privacy:")
    local privacy_combo = CREATE_COMBOBOX({"Unlisted", "Private", "Public"})
    SET_CURRENT_INDEX(privacy_combo, 0)
    LAYOUT_ADD_WIDGET(privacy_layout, privacy_label)
    LAYOUT_ADD_WIDGET(privacy_layout, privacy_combo)
    LAYOUT_ADD_STRETCH(privacy_layout)
    LAYOUT_ADD_LAYOUT(options_layout, privacy_layout)

    SET_WIDGET_LAYOUT(options_group, options_layout)
    LAYOUT_ADD_WIDGET(main_layout, options_group)

    -- === Buttons ===
    LAYOUT_ADD_SPACING(main_layout, 20)
    local button_layout = CREATE_LAYOUT("horizontal")
    LAYOUT_ADD_STRETCH(button_layout)

    local preview_video_button = CREATE_BUTTON("Preview Video")
    if not video_path then
        SET_ENABLED(preview_video_button, false)
    end

    local submit_button = CREATE_BUTTON("Submit Bug Report")
    SET_WIDGET_STYLE(submit_button, "background-color: #4CAF50; color: white; font-weight: bold; padding: 8px;")

    local cancel_button = CREATE_BUTTON("Cancel")

    LAYOUT_ADD_WIDGET(button_layout, preview_video_button)
    LAYOUT_ADD_WIDGET(button_layout, submit_button)
    LAYOUT_ADD_WIDGET(button_layout, cancel_button)
    LAYOUT_ADD_LAYOUT(main_layout, button_layout)

    -- Set dialog layout
    SET_DIALOG_LAYOUT(dialog, main_layout)

    -- Store widgets and data
    dialog.test_path = test_path
    dialog.test = test
    dialog.widgets = {
        title_edit = title_edit,
        body_text = body_text,
        upload_video = upload_video_checkbox,
        create_issue = create_issue_checkbox,
        privacy_combo = privacy_combo,
        preview_video = preview_video_button,
        submit = submit_button,
        cancel = cancel_button
    }

    return dialog
end

-- Find slideshow video for test
-- @param test_path: Path to test JSON file
-- @return: Video path or nil
function SubmissionDialog.find_slideshow_video(test_path)
    local test_dir = test_path:match("(.*/)")
    if not test_dir then
        return nil
    end

    local video_path = test_dir .. "slideshow.mp4"
    local file = io.open(video_path, "r")
    if file then
        file:close()
        return video_path
    end

    return nil
end

-- Show submission result dialog
-- @param result: Submission result from bug_submission
function SubmissionDialog.show_result(result)
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        return
    end

    local dialog = CREATE_DIALOG("Submission Complete")
    if not dialog then
        logger.error("bug_reporter", "Failed to create submission result dialog")
        return nil
    end

    local layout = CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create submission result layout")
        return nil
    end

    -- Success/failure header
    local header_label
    if result.video_url or result.issue_url then
        header_label = CREATE_LABEL("✓ Bug Report Submitted Successfully")
        SET_WIDGET_STYLE(header_label, "color: green; font-size: 14pt; font-weight: bold;")
    else
        header_label = CREATE_LABEL("✗ Submission Failed")
        SET_WIDGET_STYLE(header_label, "color: red; font-size: 14pt; font-weight: bold;")
    end
    LAYOUT_ADD_WIDGET(layout, header_label)

    LAYOUT_ADD_SPACING(layout, 10)

    -- Video URL
    if result.video_url then
        local video_label = CREATE_LABEL("Video URL:")
        SET_WIDGET_STYLE(video_label, "font-weight: bold;")
        LAYOUT_ADD_WIDGET(layout, video_label)

        local video_link = CREATE_LINE_EDIT(result.video_url)
        SET_WIDGET_PROPERTY(video_link, "readOnly", true)
        LAYOUT_ADD_WIDGET(layout, video_link)

        LAYOUT_ADD_SPACING(layout, 5)
    end

    -- Issue URL
    if result.issue_url then
        local issue_label = CREATE_LABEL("GitHub Issue:")
        SET_WIDGET_STYLE(issue_label, "font-weight: bold;")
        LAYOUT_ADD_WIDGET(layout, issue_label)

        local issue_link = CREATE_LINE_EDIT(result.issue_url)
        SET_WIDGET_PROPERTY(issue_link, "readOnly", true)
        LAYOUT_ADD_WIDGET(layout, issue_link)

        LAYOUT_ADD_SPACING(layout, 5)
    end

    -- Errors
    if result.errors and #result.errors > 0 then
        LAYOUT_ADD_SPACING(layout, 10)
        local error_label = CREATE_LABEL("Errors:")
        SET_WIDGET_STYLE(error_label, "font-weight: bold; color: red;")
        LAYOUT_ADD_WIDGET(layout, error_label)

        for _, error_msg in ipairs(result.errors) do
            local error_text = CREATE_LABEL("  • " .. error_msg)
            SET_WIDGET_STYLE(error_text, "color: red;")
            LAYOUT_ADD_WIDGET(layout, error_text)
        end
    end

    -- OK button
    LAYOUT_ADD_SPACING(layout, 20)
    local button_layout = CREATE_LAYOUT("horizontal")
    LAYOUT_ADD_STRETCH(button_layout)

    local ok_button = CREATE_BUTTON("OK")
    LAYOUT_ADD_WIDGET(button_layout, ok_button)
    LAYOUT_ADD_LAYOUT(layout, button_layout)

    SET_DIALOG_LAYOUT(dialog, layout)

    return dialog
end

-- Show progress dialog during submission
-- @return: Dialog widget with progress bar
function SubmissionDialog.show_progress()
    local has_qt = type(CREATE_DIALOG) == "function"
    if not has_qt then
        return nil
    end

    local dialog = CREATE_DIALOG("Submitting Bug Report")
    if not dialog then
        logger.error("bug_reporter", "Failed to create submission progress dialog")
        return nil
    end

    local layout = CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create submission progress layout")
        return nil
    end

    local status_label = CREATE_LABEL("Preparing submission...")
    LAYOUT_ADD_WIDGET(layout, status_label)

    LAYOUT_ADD_SPACING(layout, 10)

    local progress_bar = CREATE_PROGRESS_BAR()
    SET_WIDGET_PROPERTY(progress_bar, "minimum", 0)
    SET_WIDGET_PROPERTY(progress_bar, "maximum", 100)
    SET_WIDGET_PROPERTY(progress_bar, "value", 0)
    LAYOUT_ADD_WIDGET(layout, progress_bar)

    LAYOUT_ADD_SPACING(layout, 10)

    local cancel_button = CREATE_BUTTON("Cancel")
    LAYOUT_ADD_WIDGET(layout, cancel_button)

    SET_DIALOG_LAYOUT(dialog, layout)

    dialog.widgets = {
        status = status_label,
        progress = progress_bar,
        cancel = cancel_button
    }

    return dialog
end

-- Update progress dialog
-- @param dialog: Progress dialog
-- @param status: Status message
-- @param percent: Progress percentage (0-100)
function SubmissionDialog.update_progress(dialog, status, percent)
    if not dialog or not dialog.widgets then
        return
    end

    SET_TEXT(dialog.widgets.status, status)
    SET_WIDGET_PROPERTY(dialog.widgets.progress, "value", percent)
end

return SubmissionDialog
