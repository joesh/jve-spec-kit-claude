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
-- Size: ~274 LOC
-- Volatility: unknown
--
-- @file submission_dialog.lua
-- Original intent (unreviewed):
-- submission_dialog.lua
-- Bug submission review dialog (shows before uploading)
local json_test_loader = require("bug_reporter.json_test_loader")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local logger = require("core.logger")
local qt = require("bug_reporter.qt_compat")

local SubmissionDialog = {}

-- Create bug submission review dialog
-- @param test_path: Path to test JSON file
-- @return: Dialog widget
function SubmissionDialog.create(test_path)
    if not qt.is_available() then
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
    local dialog = qt.CREATE_DIALOG("Submit Bug Report")
    if not dialog then
        logger.error("bug_reporter", "Failed to create submission dialog")
        return nil
    end

    local main_layout = qt.CREATE_LAYOUT("vertical")
    if not main_layout then
        logger.error("bug_reporter", "Failed to create submission dialog layout")
        return nil
    end

    -- === Header ===
    local header_label = qt.CREATE_LABEL("Review Bug Report Before Submission")
    qt.SET_WIDGET_STYLE(header_label, "font-size: 14pt; font-weight: bold;")
    qt.LAYOUT_ADD_WIDGET(main_layout, header_label)

    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Test Information ===
    local info_group = qt.CREATE_GROUP_BOX("Bug Information")
    local info_layout = qt.CREATE_LAYOUT("vertical")

    -- Test name
    local name_layout = qt.CREATE_LAYOUT("horizontal")
    local name_label = qt.CREATE_LABEL("Name:")
    qt.SET_WIDGET_STYLE(name_label, "font-weight: bold; min-width: 100px;")
    local name_value = qt.CREATE_LABEL(test.test_name or test.test_id)
    qt.LAYOUT_ADD_WIDGET(name_layout, name_label)
    qt.LAYOUT_ADD_WIDGET(name_layout, name_value)
    qt.LAYOUT_ADD_STRETCH(name_layout)
    qt.LAYOUT_ADD_LAYOUT(info_layout, name_layout)

    -- Category
    local category_layout = qt.CREATE_LAYOUT("horizontal")
    local category_label = qt.CREATE_LABEL("Category:")
    qt.SET_WIDGET_STYLE(category_label, "font-weight: bold; min-width: 100px;")
    local category_value = qt.CREATE_LABEL(test.category or "bug")
    qt.LAYOUT_ADD_WIDGET(category_layout, category_label)
    qt.LAYOUT_ADD_WIDGET(category_layout, category_value)
    qt.LAYOUT_ADD_STRETCH(category_layout)
    qt.LAYOUT_ADD_LAYOUT(info_layout, category_layout)

    -- Timestamp
    if test.capture_metadata and test.capture_metadata.timestamp then
        local time_layout = qt.CREATE_LAYOUT("horizontal")
        local time_label = qt.CREATE_LABEL("Captured:")
        qt.SET_WIDGET_STYLE(time_label, "font-weight: bold; min-width: 100px;")
        local time_value = qt.CREATE_LABEL(
            os.date("%Y-%m-%d %H:%M:%S", test.capture_metadata.timestamp)
        )
        qt.LAYOUT_ADD_WIDGET(time_layout, time_label)
        qt.LAYOUT_ADD_WIDGET(time_layout, time_value)
        qt.LAYOUT_ADD_STRETCH(time_layout)
        qt.LAYOUT_ADD_LAYOUT(info_layout, time_layout)
    end

    -- Statistics
    local stats_layout = qt.CREATE_LAYOUT("horizontal")
    local stats_label = qt.CREATE_LABEL("Statistics:")
    qt.SET_WIDGET_STYLE(stats_label, "font-weight: bold; min-width: 100px;")
    local stats_text = string.format(
        "%d gestures, %d commands, %d screenshots",
        #(test.gesture_log or {}),
        #(test.command_log or {}),
        (test.screenshots and test.screenshots.screenshot_count or 0)
    )
    local stats_value = qt.CREATE_LABEL(stats_text)
    qt.LAYOUT_ADD_WIDGET(stats_layout, stats_label)
    qt.LAYOUT_ADD_WIDGET(stats_layout, stats_value)
    qt.LAYOUT_ADD_STRETCH(stats_layout)
    qt.LAYOUT_ADD_LAYOUT(info_layout, stats_layout)

    qt.SET_WIDGET_LAYOUT(info_group, info_layout)
    qt.LAYOUT_ADD_WIDGET(main_layout, info_group)

    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Preview ===
    local preview_group = qt.CREATE_GROUP_BOX("GitHub Issue Preview")
    local preview_layout = qt.CREATE_LAYOUT("vertical")

    -- Issue title
    local title_layout = qt.CREATE_LAYOUT("horizontal")
    local title_label = qt.CREATE_LABEL("Title:")
    qt.SET_WIDGET_STYLE(title_label, "font-weight: bold;")
    qt.LAYOUT_ADD_WIDGET(title_layout, title_label)
    qt.LAYOUT_ADD_LAYOUT(preview_layout, title_layout)

    local issue_title = require("bug_reporter.bug_submission").format_issue_title(test)
    local title_edit = qt.CREATE_LINE_EDIT(issue_title)
    qt.LAYOUT_ADD_WIDGET(preview_layout, title_edit)

    qt.LAYOUT_ADD_SPACING(preview_layout, 5)

    -- Issue body
    local body_label = qt.CREATE_LABEL("Body:")
    qt.SET_WIDGET_STYLE(body_label, "font-weight: bold;")
    qt.LAYOUT_ADD_WIDGET(preview_layout, body_label)

    local issue_body = github_issue_creator.format_bug_report_body(test)
    local body_text = qt.CREATE_TEXT_EDIT(issue_body)
    qt.SET_WIDGET_PROPERTY(body_text, "readOnly", true)
    qt.SET_WIDGET_PROPERTY(body_text, "minimumHeight", 200)
    qt.LAYOUT_ADD_WIDGET(preview_layout, body_text)

    qt.SET_WIDGET_LAYOUT(preview_group, preview_layout)
    qt.LAYOUT_ADD_WIDGET(main_layout, preview_group)

    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    -- === Options ===
    local options_group = qt.CREATE_GROUP_BOX("Submission Options")
    local options_layout = qt.CREATE_LAYOUT("vertical")

    local upload_video_checkbox = qt.CREATE_CHECKBOX("Upload slideshow video to YouTube")
    qt.SET_CHECKED(upload_video_checkbox, true)
    qt.LAYOUT_ADD_WIDGET(options_layout, upload_video_checkbox)

    -- Check if video exists
    local video_path = SubmissionDialog.find_slideshow_video(test_path)
    if not video_path then
        qt.SET_ENABLED(upload_video_checkbox, false)
        local no_video_label = qt.CREATE_LABEL("  (No slideshow video found)")
        qt.SET_WIDGET_STYLE(no_video_label, "color: red;")
        qt.LAYOUT_ADD_WIDGET(options_layout, no_video_label)
    else
        local video_info = qt.CREATE_LABEL("  Video: " .. video_path)
        qt.SET_WIDGET_STYLE(video_info, "color: gray; font-size: 9pt;")
        qt.LAYOUT_ADD_WIDGET(options_layout, video_info)
    end

    local create_issue_checkbox = qt.CREATE_CHECKBOX("Create GitHub issue")
    qt.SET_CHECKED(create_issue_checkbox, true)
    qt.LAYOUT_ADD_WIDGET(options_layout, create_issue_checkbox)

    local privacy_layout = qt.CREATE_LAYOUT("horizontal")
    local privacy_label = qt.CREATE_LABEL("  Video privacy:")
    local privacy_combo = qt.CREATE_COMBOBOX({"Unlisted", "Private", "Public"})
    qt.SET_CURRENT_INDEX(privacy_combo, 0)
    qt.LAYOUT_ADD_WIDGET(privacy_layout, privacy_label)
    qt.LAYOUT_ADD_WIDGET(privacy_layout, privacy_combo)
    qt.LAYOUT_ADD_STRETCH(privacy_layout)
    qt.LAYOUT_ADD_LAYOUT(options_layout, privacy_layout)

    qt.SET_WIDGET_LAYOUT(options_group, options_layout)
    qt.LAYOUT_ADD_WIDGET(main_layout, options_group)

    -- === Buttons ===
    qt.LAYOUT_ADD_SPACING(main_layout, 20)
    local button_layout = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(button_layout)

    local preview_video_button = qt.CREATE_BUTTON("Preview Video")
    if not video_path then
        qt.SET_ENABLED(preview_video_button, false)
    end

    local submit_button = qt.CREATE_BUTTON("Submit Bug Report")
    qt.SET_WIDGET_STYLE(submit_button, "background-color: #4CAF50; color: white; font-weight: bold; padding: 8px;")

    local cancel_button = qt.CREATE_BUTTON("Cancel")

    qt.LAYOUT_ADD_WIDGET(button_layout, preview_video_button)
    qt.LAYOUT_ADD_WIDGET(button_layout, submit_button)
    qt.LAYOUT_ADD_WIDGET(button_layout, cancel_button)
    qt.LAYOUT_ADD_LAYOUT(main_layout, button_layout)

    -- Set dialog layout
    qt.SET_DIALOG_LAYOUT(dialog, main_layout)

    -- Return wrapper table with dialog and metadata
    -- (dialog is C++ userdata, can't add fields to it)
    return {
        dialog = dialog,
        test_path = test_path,
        test = test,
        widgets = {
            title_edit = title_edit,
            body_text = body_text,
            upload_video = upload_video_checkbox,
            create_issue = create_issue_checkbox,
            privacy_combo = privacy_combo,
            preview_video = preview_video_button,
            submit = submit_button,
            cancel = cancel_button
        }
    }
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
    if not qt.is_available() then
        return
    end

    local dialog = qt.CREATE_DIALOG("Submission Complete")
    if not dialog then
        logger.error("bug_reporter", "Failed to create submission result dialog")
        return nil
    end

    local layout = qt.CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create submission result layout")
        return nil
    end

    -- Success/failure header
    local header_label
    if result.video_url or result.issue_url then
        header_label = qt.CREATE_LABEL("✓ Bug Report Submitted Successfully")
        qt.SET_WIDGET_STYLE(header_label, "color: green; font-size: 14pt; font-weight: bold;")
    else
        header_label = qt.CREATE_LABEL("✗ Submission Failed")
        qt.SET_WIDGET_STYLE(header_label, "color: red; font-size: 14pt; font-weight: bold;")
    end
    qt.LAYOUT_ADD_WIDGET(layout, header_label)

    qt.LAYOUT_ADD_SPACING(layout, 10)

    -- Video URL
    if result.video_url then
        local video_label = qt.CREATE_LABEL("Video URL:")
        qt.SET_WIDGET_STYLE(video_label, "font-weight: bold;")
        qt.LAYOUT_ADD_WIDGET(layout, video_label)

        local video_link = qt.CREATE_LINE_EDIT(result.video_url)
        qt.SET_WIDGET_PROPERTY(video_link, "readOnly", true)
        qt.LAYOUT_ADD_WIDGET(layout, video_link)

        qt.LAYOUT_ADD_SPACING(layout, 5)
    end

    -- Issue URL
    if result.issue_url then
        local issue_label = qt.CREATE_LABEL("GitHub Issue:")
        qt.SET_WIDGET_STYLE(issue_label, "font-weight: bold;")
        qt.LAYOUT_ADD_WIDGET(layout, issue_label)

        local issue_link = qt.CREATE_LINE_EDIT(result.issue_url)
        qt.SET_WIDGET_PROPERTY(issue_link, "readOnly", true)
        qt.LAYOUT_ADD_WIDGET(layout, issue_link)

        qt.LAYOUT_ADD_SPACING(layout, 5)
    end

    -- Errors
    if result.errors and #result.errors > 0 then
        qt.LAYOUT_ADD_SPACING(layout, 10)
        local error_label = qt.CREATE_LABEL("Errors:")
        qt.SET_WIDGET_STYLE(error_label, "font-weight: bold; color: red;")
        qt.LAYOUT_ADD_WIDGET(layout, error_label)

        for _, error_msg in ipairs(result.errors) do
            local error_text = qt.CREATE_LABEL("  • " .. error_msg)
            qt.SET_WIDGET_STYLE(error_text, "color: red;")
            qt.LAYOUT_ADD_WIDGET(layout, error_text)
        end
    end

    -- OK button
    qt.LAYOUT_ADD_SPACING(layout, 20)
    local button_layout = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(button_layout)

    local ok_button = qt.CREATE_BUTTON("OK")
    qt.LAYOUT_ADD_WIDGET(button_layout, ok_button)
    qt.LAYOUT_ADD_LAYOUT(layout, button_layout)

    qt.SET_DIALOG_LAYOUT(dialog, layout)

    return dialog
end

-- Show progress dialog during submission
-- @return: Dialog widget with progress bar
function SubmissionDialog.show_progress()
    if not qt.is_available() then
        return nil
    end

    local dialog = qt.CREATE_DIALOG("Submitting Bug Report")
    if not dialog then
        logger.error("bug_reporter", "Failed to create submission progress dialog")
        return nil
    end

    local layout = qt.CREATE_LAYOUT("vertical")
    if not layout then
        logger.error("bug_reporter", "Failed to create submission progress layout")
        return nil
    end

    local status_label = qt.CREATE_LABEL("Preparing submission...")
    qt.LAYOUT_ADD_WIDGET(layout, status_label)

    qt.LAYOUT_ADD_SPACING(layout, 10)

    local progress_bar = qt.CREATE_PROGRESS_BAR()
    qt.SET_WIDGET_PROPERTY(progress_bar, "minimum", 0)
    qt.SET_WIDGET_PROPERTY(progress_bar, "maximum", 100)
    qt.SET_WIDGET_PROPERTY(progress_bar, "value", 0)
    qt.LAYOUT_ADD_WIDGET(layout, progress_bar)

    qt.LAYOUT_ADD_SPACING(layout, 10)

    local cancel_button = qt.CREATE_BUTTON("Cancel")
    qt.LAYOUT_ADD_WIDGET(layout, cancel_button)

    qt.SET_DIALOG_LAYOUT(dialog, layout)

    -- Return wrapper table (dialog is C++ userdata)
    return {
        dialog = dialog,
        widgets = {
            status = status_label,
            progress = progress_bar,
            cancel = cancel_button
        }
    }
end

-- Update progress dialog
-- @param wrapper: Progress dialog wrapper table
-- @param status: Status message
-- @param percent: Progress percentage (0-100)
function SubmissionDialog.update_progress(wrapper, status, percent)
    if not wrapper or not wrapper.widgets then
        return
    end

    qt.SET_TEXT(wrapper.widgets.status, status)
    qt.SET_WIDGET_PROPERTY(wrapper.widgets.progress, "value", percent)
end

return SubmissionDialog
