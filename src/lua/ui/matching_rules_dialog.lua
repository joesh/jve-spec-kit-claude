--- matching_rules_dialog: blocking modal for configuring relink matching criteria
--
-- Responsibilities:
-- - Show checkboxes for match criteria and options
-- - Validate at least one of Filename or Timecode is checked
-- - Return updated rules table or nil on cancel
--
-- @file matching_rules_dialog.lua
local M = {}

--- Show the matching rules configuration dialog (blocking modal).
-- @param current_rules table Current matching rules
-- @param parent_window widget|nil Qt parent widget
-- @return table|nil Updated rules on OK, nil on cancel
function M.show(current_rules, parent_window)
    assert(type(current_rules) == "table", "matching_rules_dialog.show: current_rules required")

    local qt = require("core.qt_constants")

    local result_rules = nil
    local globals = {}

    local dialog = qt.DIALOG.CREATE("Matching Rules", 400, 320, parent_window)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- -----------------------------------------------------------------------
    -- Match By section
    -- -----------------------------------------------------------------------
    local match_label = qt.WIDGET.CREATE_LABEL("Match By:")
    qt.PROPERTIES.SET_STYLE(match_label, "font-weight: bold; font-size: 13px;")
    qt.LAYOUT.ADD_WIDGET(main_layout, match_label)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    local cb_filename = qt.WIDGET.CREATE_CHECKBOX()
    qt.PROPERTIES.SET_TEXT(cb_filename, "Filename")
    qt.PROPERTIES.SET_CHECKED(cb_filename, current_rules.match_filename ~= false)
    qt.LAYOUT.ADD_WIDGET(main_layout, cb_filename)

    local cb_timecode = qt.WIDGET.CREATE_CHECKBOX()
    qt.PROPERTIES.SET_TEXT(cb_timecode, "Timecode")
    qt.PROPERTIES.SET_CHECKED(cb_timecode, current_rules.match_timecode ~= false)
    qt.LAYOUT.ADD_WIDGET(main_layout, cb_timecode)

    local cb_resolution = qt.WIDGET.CREATE_CHECKBOX()
    qt.PROPERTIES.SET_TEXT(cb_resolution, "Resolution")
    qt.PROPERTIES.SET_CHECKED(cb_resolution, current_rules.match_resolution == true)
    qt.LAYOUT.ADD_WIDGET(main_layout, cb_resolution)

    local cb_framerate = qt.WIDGET.CREATE_CHECKBOX()
    qt.PROPERTIES.SET_TEXT(cb_framerate, "Frame Rate")
    qt.PROPERTIES.SET_CHECKED(cb_framerate, current_rules.match_frame_rate == true)
    qt.LAYOUT.ADD_WIDGET(main_layout, cb_framerate)

    qt.LAYOUT.ADD_SPACING(main_layout, 12)

    -- -----------------------------------------------------------------------
    -- Options section
    -- -----------------------------------------------------------------------
    local options_label = qt.WIDGET.CREATE_LABEL("Options:")
    qt.PROPERTIES.SET_STYLE(options_label, "font-weight: bold; font-size: 13px;")
    qt.LAYOUT.ADD_WIDGET(main_layout, options_label)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    local cb_trimmed = qt.WIDGET.CREATE_CHECKBOX()
    qt.PROPERTIES.SET_TEXT(cb_trimmed, "Accept Trimmed Media")
    qt.PROPERTIES.SET_CHECKED(cb_trimmed, current_rules.accept_trimmed_media == true)
    qt.LAYOUT.ADD_WIDGET(main_layout, cb_trimmed)

    local cb_suffixes = qt.WIDGET.CREATE_CHECKBOX()
    qt.PROPERTIES.SET_TEXT(cb_suffixes, "Accept Filename Suffixes")
    qt.PROPERTIES.SET_CHECKED(cb_suffixes, current_rules.accept_filename_suffixes == true)
    qt.LAYOUT.ADD_WIDGET(main_layout, cb_suffixes)

    qt.LAYOUT.ADD_SPACING(main_layout, 8)

    -- -----------------------------------------------------------------------
    -- Error label (hidden)
    -- -----------------------------------------------------------------------
    local error_label = qt.WIDGET.CREATE_LABEL("")
    qt.PROPERTIES.SET_STYLE(error_label, "color: #ff6666;")
    qt.DISPLAY.SET_VISIBLE(error_label, false)
    qt.LAYOUT.ADD_WIDGET(main_layout, error_label)

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- -----------------------------------------------------------------------
    -- Button row
    -- -----------------------------------------------------------------------
    local btn_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_STRETCH(btn_row)

    local ok_btn = qt.WIDGET.CREATE_BUTTON("OK")
    local cancel_btn = qt.WIDGET.CREATE_BUTTON("Cancel")

    local cancel_name = "__matching_rules_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(cancel_btn, cancel_name)
    globals[#globals + 1] = cancel_name

    local ok_name = "__matching_rules_ok"
    _G[ok_name] = function()
        local fn_checked = qt.PROPERTIES.GET_CHECKED(cb_filename)
        local tc_checked = qt.PROPERTIES.GET_CHECKED(cb_timecode)

        -- Validate: at least one of Filename or Timecode
        if not fn_checked and not tc_checked then
            qt.PROPERTIES.SET_TEXT(error_label,
                "At least one of Filename or Timecode must be checked")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        result_rules = {
            match_filename = fn_checked,
            match_timecode = tc_checked,
            match_resolution = qt.PROPERTIES.GET_CHECKED(cb_resolution),
            match_frame_rate = qt.PROPERTIES.GET_CHECKED(cb_framerate),
            accept_trimmed_media = qt.PROPERTIES.GET_CHECKED(cb_trimmed),
            accept_filename_suffixes = qt.PROPERTIES.GET_CHECKED(cb_suffixes),
        }
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ok_btn, ok_name)
    globals[#globals + 1] = ok_name

    qt.LAYOUT.ADD_WIDGET(btn_row, ok_btn)
    qt.LAYOUT.ADD_SPACING(btn_row, 8)
    qt.LAYOUT.ADD_WIDGET(btn_row, cancel_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, btn_row)

    -- -----------------------------------------------------------------------
    -- Show (blocking)
    -- -----------------------------------------------------------------------
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    if qt.PROPERTIES.SET_WINDOW_APPEARANCE then
        pcall(qt.PROPERTIES.SET_WINDOW_APPEARANCE, dialog, "NSAppearanceNameDarkAqua")
    end
    qt.DIALOG.SHOW(dialog)

    -- Cleanup
    for _, name in ipairs(globals) do
        _G[name] = nil
    end

    return result_rules
end

--- Return default matching rules.
-- @return table Default rules (filename + timecode on, rest off)
function M.default_rules()
    return {
        match_filename = true,
        match_timecode = true,
        match_resolution = false,
        match_frame_rate = false,
        accept_trimmed_media = false,
        accept_filename_suffixes = false,
    }
end

return M
