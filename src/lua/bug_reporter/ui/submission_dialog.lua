-- Feature 027 T013: bug-report submission dialog. View layer per
-- Constitution I MVC — owns the widgets, binds them to a
-- submission_state model (T012), and routes user actions to the
-- ReportBug submit handler (T014c).
--
-- Phase A surface:
--   - Title field (required for Submit)
--   - Multiline description
--   - Text-only checkbox (excludes slideshow.mp4 from the zip)
--   - Submit + Cancel buttons
--
-- All references to YouTube/OAuth/github_issue_creator/json_test_loader
-- dropped — those modules are slated for delete in T015 / T052.

local qt = require("bug_reporter.qt_compat")
local log = require("core.logger").for_area("ui")

local M = {}

local function build_widgets(state, vbox)
    local title_label = qt.CREATE_LABEL("Title (required):")
    qt.LAYOUT_ADD_WIDGET(vbox, title_label)
    local title_edit = qt.CREATE_LINE_EDIT(state.title or "")
    qt.LAYOUT_ADD_WIDGET(vbox, title_edit)
    if qt_set_line_edit_text_changed_handler then
        qt_set_line_edit_text_changed_handler(title_edit, function(new_text)
            state:set_title(new_text or "")
        end)
    end

    local desc_label = qt.CREATE_LABEL("Description:")
    qt.LAYOUT_ADD_WIDGET(vbox, desc_label)
    local desc_edit = qt.CREATE_TEXT_EDIT(state.description or "")
    qt.LAYOUT_ADD_WIDGET(vbox, desc_edit)

    -- FR-006: Text-only opt-out.
    local text_only_cb = qt.CREATE_CHECKBOX("Text only (exclude slideshow video)")
    qt.LAYOUT_ADD_WIDGET(vbox, text_only_cb)
    if _G.qt_set_check_box_state_changed_handler then
        _G.qt_set_check_box_state_changed_handler(text_only_cb, function(checked)
            state:set_text_only(checked and true or false)
        end)
    end

    local btn_row = qt.CREATE_LAYOUT("horizontal")
    qt.LAYOUT_ADD_STRETCH(btn_row)
    local cancel_btn = qt.CREATE_BUTTON("Cancel")
    qt.LAYOUT_ADD_WIDGET(btn_row, cancel_btn)
    local submit_btn = qt.CREATE_BUTTON("Submit")
    qt.LAYOUT_ADD_WIDGET(btn_row, submit_btn)
    qt.LAYOUT_ADD_LAYOUT(vbox, btn_row)

    return {
        title_edit = title_edit,
        desc_edit  = desc_edit,
        text_only  = text_only_cb,
        submit_btn = submit_btn,
        cancel_btn = cancel_btn,
    }
end

-- Public: create a submission dialog bound to `state` (T012). Returns
-- a wrapper:
--   { dialog, widgets, on_submit(), on_cancel() }
function M.create(state)
    assert(state and type(state.is_submittable) == "function",
        "submission_dialog.create: requires a submission_state instance")

    local dialog = qt.CREATE_DIALOG("Submit Bug Report", 520, 480)
    local vbox = qt.CREATE_LAYOUT("vertical")
    qt.SET_WIDGET_LAYOUT(dialog, vbox)

    local widgets = build_widgets(state, vbox)

    local wrapper = {
        dialog  = dialog,
        widgets = widgets,
    }

    function wrapper.on_submit()
        if not state:is_submittable() then
            log.warn("submission_dialog: Submit invoked but state is not submittable — ignoring")
            return false
        end
        local report_bug = require("core.commands.report_bug")
        assert(type(report_bug.submit) == "function",
            "submission_dialog: core.commands.report_bug.submit missing (T014c)")
        local result = report_bug.submit(state)
        qt.CLOSE_DIALOG(dialog, true)
        return result and result.ok or false
    end

    function wrapper.on_cancel()
        qt.CLOSE_DIALOG(dialog, false)
    end

    if qt_set_button_click_handler then
        qt_set_button_click_handler(widgets.submit_btn, wrapper.on_submit)
        qt_set_button_click_handler(widgets.cancel_btn, wrapper.on_cancel)
    end

    return wrapper
end

return M
