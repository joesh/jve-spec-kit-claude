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

    local desc_label = qt.CREATE_LABEL("Description:")
    qt.LAYOUT_ADD_WIDGET(vbox, desc_label)
    local desc_edit = qt.CREATE_TEXT_EDIT(state.description or "")
    qt.LAYOUT_ADD_WIDGET(vbox, desc_edit)

    -- FR-006: Text-only opt-out.
    local text_only_cb = qt.CREATE_CHECKBOX("Text only (exclude slideshow video)")
    qt.LAYOUT_ADD_WIDGET(vbox, text_only_cb)

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

-- Pull widget values into the state model. Called from Submit so the
-- state reflects whatever the user typed (the change-handler bindings
-- take a global function NAME not a closure; pull-at-Submit is simpler
-- than per-keystroke push). Module-level so the widget→state contract
-- is independently testable without driving the full submit pipeline.
function M.sync_state_from_widgets(state, widgets)
    assert(state and widgets, "sync_state_from_widgets: state and widgets required")
    assert(widgets.title_edit and widgets.desc_edit and widgets.text_only,
        "sync_state_from_widgets: expected title_edit, desc_edit, text_only widgets")
    state:set_title(qt.GET_TEXT(widgets.title_edit))
    state:set_description(qt.GET_TEXT(widgets.desc_edit))
    state:set_text_only(qt.GET_CHECKED(widgets.text_only) and true or false)
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

    -- Named-global pattern: qt_set_button_click_handler only accepts a
    -- global-name string, not a function literal (see ui/welcome_screen.lua).
    -- Handlers nil their own slots before returning — the executing function
    -- holds its own stack reference, so clearing _G mid-call is safe and
    -- removes the leak without forcing callers to remember a cleanup step.
    local submit_name = "__bug_reporter_submit_dialog_submit"
    local cancel_name = "__bug_reporter_submit_dialog_cancel"

    function wrapper.on_submit()
        M.sync_state_from_widgets(state, widgets)
        if not state:is_submittable() then
            log.warn("submission_dialog: Submit invoked but state is not submittable — title=%q desc_len=%d text_only=%s",
                tostring(state.title), #(state.description or ""), tostring(state.text_only))
            return false
        end
        local report_bug = require("core.commands.report_bug")
        assert(type(report_bug.submit) == "function",
            "submission_dialog: core.commands.report_bug.submit missing (T014c)")
        report_bug.submit(state, function(result)
            wrapper.last_result = result
            qt.CLOSE_DIALOG(dialog, true)
            _G[submit_name] = nil
            _G[cancel_name] = nil
        end)
        return true
    end

    function wrapper.on_cancel()
        qt.CLOSE_DIALOG(dialog, false)
        _G[submit_name] = nil
        _G[cancel_name] = nil
    end

    _G[submit_name] = wrapper.on_submit
    _G[cancel_name] = wrapper.on_cancel
    qt_set_button_click_handler(widgets.submit_btn, submit_name)
    qt_set_button_click_handler(widgets.cancel_btn, cancel_name)

    return wrapper
end

return M
