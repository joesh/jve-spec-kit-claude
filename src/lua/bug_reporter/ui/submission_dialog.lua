--- submission_dialog.lua
-- Bug submission review dialog (shows before uploading)
local json_test_loader = require("bug_reporter.json_test_loader")
local github_issue_creator = require("bug_reporter.github_issue_creator")
local log = require("core.logger").for_area("ui")
local qt = require("bug_reporter.qt_compat")
local ui_constants = require("core.ui_constants")

local SubmissionDialog = {}

-- Create bug submission review dialog
-- @param test_path: Path to test JSON file
-- @return: Dialog widget
-- Helper: build a `<bold-label> <value>` row with min-width on the label.
local function build_info_row(layout, label_text, value_text)
    local row = qt.CREATE_LAYOUT("horizontal")
    local label = qt.CREATE_LABEL(label_text)
    qt.SET_WIDGET_STYLE(label, "font-weight: bold; min-width: 100px;")
    qt.LAYOUT_ADD_WIDGET(row, label)
    qt.LAYOUT_ADD_WIDGET(row, qt.CREATE_LABEL(value_text))
    qt.LAYOUT_ADD_STRETCH(row)
    qt.LAYOUT_ADD_LAYOUT(layout, row)
end

local function build_info_section(test)
    local group  = qt.CREATE_GROUP_BOX("Bug Information")
    local layout = qt.CREATE_LAYOUT("vertical")

    build_info_row(layout, "Name:",     test.test_name or test.test_id)
    build_info_row(layout, "Category:", test.category or "bug")
    if test.capture_metadata and test.capture_metadata.timestamp then
        build_info_row(layout, "Captured:",
            os.date("%Y-%m-%d %H:%M:%S", test.capture_metadata.timestamp))
    end
    build_info_row(layout, "Statistics:", string.format(
        "%d gestures, %d commands, %d screenshots",
        #(test.gesture_log or {}),
        #(test.command_log or {}),
        (test.screenshots and test.screenshots.screenshot_count or 0)))

    qt.SET_WIDGET_LAYOUT(group, layout)
    return group
end

local function build_preview_section(test)
    local group  = qt.CREATE_GROUP_BOX("GitHub Issue Preview")
    local layout = qt.CREATE_LAYOUT("vertical")

    local title_row = qt.CREATE_LAYOUT("horizontal")
    local title_label = qt.CREATE_LABEL("Title:")
    qt.SET_WIDGET_STYLE(title_label, "font-weight: bold;")
    qt.LAYOUT_ADD_WIDGET(title_row, title_label)
    qt.LAYOUT_ADD_LAYOUT(layout, title_row)

    local issue_title = require("bug_reporter.bug_submission").format_issue_title(test)
    local title_edit = qt.CREATE_LINE_EDIT(issue_title)
    qt.LAYOUT_ADD_WIDGET(layout, title_edit)

    qt.LAYOUT_ADD_SPACING(layout, 5)

    local body_label = qt.CREATE_LABEL("Body:")
    qt.SET_WIDGET_STYLE(body_label, "font-weight: bold;")
    qt.LAYOUT_ADD_WIDGET(layout, body_label)

    local body_text = qt.CREATE_TEXT_EDIT(github_issue_creator.format_bug_report_body(test))
    qt.SET_WIDGET_PROPERTY(body_text, "readOnly", true)
    qt.SET_WIDGET_PROPERTY(body_text, "minimumHeight", 200)
    qt.LAYOUT_ADD_WIDGET(layout, body_text)

    qt.SET_WIDGET_LAYOUT(group, layout)
    return group, title_edit, body_text
end

local function build_options_section(video_path)
    local group  = qt.CREATE_GROUP_BOX("Submission Options")
    local layout = qt.CREATE_LAYOUT("vertical")

    local upload_video = qt.CREATE_CHECKBOX("Upload slideshow video to YouTube")
    qt.SET_CHECKED(upload_video, true)
    qt.LAYOUT_ADD_WIDGET(layout, upload_video)

    if not video_path then
        qt.SET_ENABLED(upload_video, false)
        local note = qt.CREATE_LABEL("  (No slideshow video found)")
        qt.SET_WIDGET_STYLE(note, "color: red;")
        qt.LAYOUT_ADD_WIDGET(layout, note)
    else
        local info = qt.CREATE_LABEL("  Video: " .. video_path)
        qt.SET_WIDGET_STYLE(info, "color: gray; font-size: 9pt;")
        qt.LAYOUT_ADD_WIDGET(layout, info)
    end

    local create_issue = qt.CREATE_CHECKBOX("Create GitHub issue")
    qt.SET_CHECKED(create_issue, true)
    qt.LAYOUT_ADD_WIDGET(layout, create_issue)

    local privacy_row = qt.CREATE_LAYOUT("horizontal")
    local privacy_combo = qt.CREATE_COMBOBOX({"Unlisted", "Private", "Public"})
    qt.SET_CURRENT_INDEX(privacy_combo, 0)
    qt.LAYOUT_ADD_WIDGET(privacy_row, qt.CREATE_LABEL("  Video privacy:"))
    qt.LAYOUT_ADD_WIDGET(privacy_row, privacy_combo)
    qt.LAYOUT_ADD_STRETCH(privacy_row)
    qt.LAYOUT_ADD_LAYOUT(layout, privacy_row)

    qt.SET_WIDGET_LAYOUT(group, layout)
    return group, upload_video, create_issue, privacy_combo
end

local function build_button_row(video_path)
    local row = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(row)

    local preview_btn = qt.CREATE_BUTTON("Preview Video")
    if not video_path then qt.SET_ENABLED(preview_btn, false) end

    local submit_btn = qt.CREATE_BUTTON("Submit Bug Report")
    qt.SET_WIDGET_STYLE(submit_btn,
        "background-color: " .. ui_constants.COLORS.ACCENT_SUCCESS .. "; color: white; font-weight: bold; padding: 8px;")

    local cancel_btn = qt.CREATE_BUTTON("Cancel")

    qt.LAYOUT_ADD_WIDGET(row, preview_btn)
    qt.LAYOUT_ADD_WIDGET(row, submit_btn)
    qt.LAYOUT_ADD_WIDGET(row, cancel_btn)
    return row, preview_btn, submit_btn, cancel_btn
end

function SubmissionDialog.create(test_path)
    if not qt.is_available() then
        log.error("Qt bindings not available for submission dialog")
        return nil
    end

    local test, err = json_test_loader.load(test_path)
    if not test then
        log.error("Failed to load test: %s", err)
        return nil
    end

    local dialog = qt.CREATE_DIALOG("Submit Bug Report")
    if not dialog then
        log.error("Failed to create submission dialog")
        return nil
    end

    local main_layout = qt.CREATE_LAYOUT("vertical")
    if not main_layout then
        log.error("Failed to create submission dialog layout")
        return nil
    end

    local header = qt.CREATE_LABEL("Review Bug Report Before Submission")
    qt.SET_WIDGET_STYLE(header, "font-size: 14pt; font-weight: bold;")
    qt.LAYOUT_ADD_WIDGET(main_layout, header)
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    qt.LAYOUT_ADD_WIDGET(main_layout, build_info_section(test))
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    local preview_group, title_edit, body_text = build_preview_section(test)
    qt.LAYOUT_ADD_WIDGET(main_layout, preview_group)
    qt.LAYOUT_ADD_SPACING(main_layout, 10)

    local video_path = SubmissionDialog.find_slideshow_video(test_path)
    local options_group, upload_video, create_issue, privacy_combo =
        build_options_section(video_path)
    qt.LAYOUT_ADD_WIDGET(main_layout, options_group)

    qt.LAYOUT_ADD_SPACING(main_layout, 20)
    local button_row, preview_video, submit, cancel = build_button_row(video_path)
    qt.LAYOUT_ADD_LAYOUT(main_layout, button_row)

    qt.SET_DIALOG_LAYOUT(dialog, main_layout)

    return {
        dialog = dialog,
        test_path = test_path,
        test = test,
        widgets = {
            title_edit    = title_edit,
            body_text     = body_text,
            upload_video  = upload_video,
            create_issue  = create_issue,
            privacy_combo = privacy_combo,
            preview_video = preview_video,
            submit        = submit,
            cancel        = cancel,
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
        log.error("Failed to create submission result dialog")
        return nil
    end

    local layout = qt.CREATE_LAYOUT("vertical")
    if not layout then
        log.error("Failed to create submission result layout")
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
        log.error("Failed to create submission progress dialog")
        return nil
    end

    local layout = qt.CREATE_LAYOUT("vertical")
    if not layout then
        log.error("Failed to create submission progress layout")
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
