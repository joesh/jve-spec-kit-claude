-- Media Relinking Configuration Dialog
-- Pure Lua UI for customizing metadata matching algorithm
-- Architecture: Uses Qt bindings, fully customizable without recompilation

local M = {}

-- Qt bindings (set externally)
local qt = nil

--- Initialize dialog with Qt bindings
-- @param qt_bindings table Qt bindings module
function M.init(qt_bindings)
    qt = qt_bindings
end

--- Create relinking configuration dialog
-- @param offline_count number Count of offline media files
-- @param callback function(config) Called when user clicks "Relink" with configuration
-- @return table Dialog widget
function M.create_dialog(offline_count, callback)
    if not qt then
        error("Media relink dialog not initialized - call init(qt_bindings) first")
    end

    -- Create dialog window
    local dialog = qt.CREATE_DIALOG("Media Relinking", 600, 500)

    -- Main layout
    local main_layout = qt.CREATE_LAYOUT("vertical")

    -- Header section
    local header_label = qt.CREATE_LABEL(string.format(
        "Found %d offline media file(s). Configure matching criteria:", offline_count))
    qt.SET_LABEL_STYLE(header_label, "font-weight: bold; font-size: 14px; margin-bottom: 10px;")
    qt.ADD_WIDGET(main_layout, header_label)

    -- Separator
    qt.ADD_WIDGET(main_layout, qt.CREATE_SEPARATOR())

    -- Matching criteria section
    local criteria_group = qt.CREATE_GROUP_BOX("Matching Criteria")
    local criteria_layout = qt.CREATE_LAYOUT("vertical")

    -- Checkboxes for each criterion with weight sliders
    local criteria_widgets = {}

    local function add_criterion(key, label, default_enabled, default_weight, description)
        local criterion_layout = qt.CREATE_LAYOUT("horizontal")

        -- Checkbox
        local checkbox = qt.CREATE_CHECKBOX(label)
        qt.SET_CHECKED(checkbox, default_enabled)
        qt.ADD_WIDGET(criterion_layout, checkbox)

        -- Weight slider (0-100 for display, converted to 0-1.0)
        local slider_label = qt.CREATE_LABEL(string.format("Weight: %d%%", default_weight * 100))
        qt.SET_FIXED_WIDTH(slider_label, 100)
        qt.ADD_WIDGET(criterion_layout, slider_label)

        local slider = qt.CREATE_SLIDER(0, 100, default_weight * 100)
        qt.SET_FIXED_WIDTH(slider, 150)

        -- Update label when slider moves
        qt.CONNECT_SLIDER(slider, function(value)
            qt.SET_LABEL_TEXT(slider_label, string.format("Weight: %d%%", value))
        end)

        qt.ADD_WIDGET(criterion_layout, slider)

        -- Add spacer
        qt.ADD_STRETCH(criterion_layout)

        qt.ADD_WIDGET(criteria_layout, criterion_layout)

        -- Description label
        local desc_label = qt.CREATE_LABEL(description)
        qt.SET_LABEL_STYLE(desc_label, "color: #888; font-size: 11px; margin-left: 20px; margin-bottom: 8px;")
        qt.ADD_WIDGET(criteria_layout, desc_label)

        criteria_widgets[key] = {
            checkbox = checkbox,
            slider = slider,
            slider_label = slider_label
        }
    end

    -- Add criteria
    add_criterion("duration", "Duration", true, 0.3,
        "Match files with similar duration (±5% tolerance)")

    add_criterion("resolution", "Resolution", true, 0.4,
        "Match files with exact width × height (critical for video quality)")

    add_criterion("timecode", "Timecode", false, 0.2,
        "Match files by embedded timecode (ideal for multi-cam and dual-system sound)")

    add_criterion("reel_name", "Reel Name", false, 0.1,
        "Match files by camera reel/card name (A001, REEL_B, MAG_C, etc.)")

    add_criterion("filename", "Filename Similarity", false, 0.0,
        "Match files by filename similarity (handles minor renames)")

    qt.SET_LAYOUT(criteria_group, criteria_layout)
    qt.ADD_WIDGET(main_layout, criteria_group)

    -- Advanced settings section
    local advanced_group = qt.CREATE_GROUP_BOX("Advanced Settings")
    local advanced_layout = qt.CREATE_LAYOUT("vertical")

    -- Duration tolerance
    local tolerance_layout = qt.CREATE_LAYOUT("horizontal")
    qt.ADD_WIDGET(tolerance_layout, qt.CREATE_LABEL("Duration Tolerance:"))

    local tolerance_label = qt.CREATE_LABEL("±5%")
    qt.SET_FIXED_WIDTH(tolerance_label, 60)
    qt.ADD_WIDGET(tolerance_layout, tolerance_label)

    local tolerance_slider = qt.CREATE_SLIDER(1, 20, 5)  -- 1-20%
    qt.SET_FIXED_WIDTH(tolerance_slider, 200)
    qt.CONNECT_SLIDER(tolerance_slider, function(value)
        qt.SET_LABEL_TEXT(tolerance_label, string.format("±%d%%", value))
    end)
    qt.ADD_WIDGET(tolerance_layout, tolerance_slider)
    qt.ADD_STRETCH(tolerance_layout)
    qt.ADD_WIDGET(advanced_layout, tolerance_layout)

    -- Minimum confidence threshold
    local confidence_layout = qt.CREATE_LAYOUT("horizontal")
    qt.ADD_WIDGET(confidence_layout, qt.CREATE_LABEL("Minimum Confidence:"))

    local confidence_label = qt.CREATE_LABEL("85%")
    qt.SET_FIXED_WIDTH(confidence_label, 60)
    qt.ADD_WIDGET(confidence_layout, confidence_label)

    local confidence_slider = qt.CREATE_SLIDER(50, 100, 85)
    qt.SET_FIXED_WIDTH(confidence_slider, 200)
    qt.CONNECT_SLIDER(confidence_slider, function(value)
        qt.SET_LABEL_TEXT(confidence_label, string.format("%d%%", value))
    end)
    qt.ADD_WIDGET(confidence_layout, confidence_slider)
    qt.ADD_STRETCH(confidence_layout)
    qt.ADD_WIDGET(advanced_layout, confidence_layout)

    qt.SET_LAYOUT(advanced_group, advanced_layout)
    qt.ADD_WIDGET(main_layout, advanced_group)

    -- Search paths section
    local paths_group = qt.CREATE_GROUP_BOX("Search Locations")
    local paths_layout = qt.CREATE_LAYOUT("vertical")

    -- Path list
    local path_list = qt.CREATE_LIST_WIDGET()
    qt.SET_FIXED_HEIGHT(path_list, 100)
    qt.ADD_WIDGET(paths_layout, path_list)

    -- Path buttons
    local path_buttons_layout = qt.CREATE_LAYOUT("horizontal")
    local add_path_button = qt.CREATE_BUTTON("Add Directory...")
    local remove_path_button = qt.CREATE_BUTTON("Remove")

    qt.CONNECT_BUTTON(add_path_button, function()
        local dir = qt.SELECT_DIRECTORY("Select Search Directory")
        if dir and dir ~= "" then
            qt.LIST_ADD_ITEM(path_list, dir)
        end
    end)

    qt.CONNECT_BUTTON(remove_path_button, function()
        local selected = qt.LIST_GET_SELECTED(path_list)
        if selected then
            qt.LIST_REMOVE_ITEM(path_list, selected)
        end
    end)

    qt.ADD_WIDGET(path_buttons_layout, add_path_button)
    qt.ADD_WIDGET(path_buttons_layout, remove_path_button)
    qt.ADD_STRETCH(path_buttons_layout)
    qt.ADD_WIDGET(paths_layout, path_buttons_layout)

    qt.SET_LAYOUT(paths_group, paths_layout)
    qt.ADD_WIDGET(main_layout, paths_group)

    -- Spacer before buttons
    qt.ADD_STRETCH(main_layout)

    -- Button bar
    local button_layout = qt.CREATE_LAYOUT("horizontal")
    qt.ADD_STRETCH(button_layout)

    local cancel_button = qt.CREATE_BUTTON("Cancel")
    local relink_button = qt.CREATE_BUTTON("Relink Media")
    qt.SET_BUTTON_STYLE(relink_button, "primary")  -- Highlight as primary action

    qt.CONNECT_BUTTON(cancel_button, function()
        qt.CLOSE_DIALOG(dialog)
    end)

    qt.CONNECT_BUTTON(relink_button, function()
        -- Gather configuration from UI
        local config = {
            -- Criteria flags
            use_duration = qt.IS_CHECKED(criteria_widgets.duration.checkbox),
            use_resolution = qt.IS_CHECKED(criteria_widgets.resolution.checkbox),
            use_timecode = qt.IS_CHECKED(criteria_widgets.timecode.checkbox),
            use_reel_name = qt.IS_CHECKED(criteria_widgets.reel_name.checkbox),
            use_filename = qt.IS_CHECKED(criteria_widgets.filename.checkbox),

            -- Weights (convert from 0-100 to 0-1.0)
            weight_duration = qt.GET_SLIDER_VALUE(criteria_widgets.duration.slider) / 100.0,
            weight_resolution = qt.GET_SLIDER_VALUE(criteria_widgets.resolution.slider) / 100.0,
            weight_timecode = qt.GET_SLIDER_VALUE(criteria_widgets.timecode.slider) / 100.0,
            weight_reel_name = qt.GET_SLIDER_VALUE(criteria_widgets.reel_name.slider) / 100.0,
            weight_filename = qt.GET_SLIDER_VALUE(criteria_widgets.filename.slider) / 100.0,

            -- Advanced settings
            duration_tolerance = qt.GET_SLIDER_VALUE(tolerance_slider) / 100.0,  -- Convert % to decimal
            min_score = qt.GET_SLIDER_VALUE(confidence_slider) / 100.0,

            -- Search paths
            search_paths = qt.LIST_GET_ALL_ITEMS(path_list)
        }

        -- Validate configuration
        local total_weight = 0
        if config.use_duration then total_weight = total_weight + config.weight_duration end
        if config.use_resolution then total_weight = total_weight + config.weight_resolution end
        if config.use_timecode then total_weight = total_weight + config.weight_timecode end
        if config.use_reel_name then total_weight = total_weight + config.weight_reel_name end
        if config.use_filename then total_weight = total_weight + config.weight_filename end

        if total_weight == 0 then
            qt.SHOW_ERROR("No Criteria Selected", "Please enable at least one matching criterion")
            return
        end

        if #config.search_paths == 0 then
            qt.SHOW_ERROR("No Search Paths", "Please add at least one directory to search")
            return
        end

        -- Close dialog and execute callback
        qt.CLOSE_DIALOG(dialog)
        if callback then
            callback(config)
        end
    end)

    qt.ADD_WIDGET(button_layout, cancel_button)
    qt.ADD_WIDGET(button_layout, relink_button)

    qt.ADD_WIDGET(main_layout, button_layout)

    -- Set dialog layout
    qt.SET_LAYOUT(dialog, main_layout)

    return dialog
end

--- Show the relinking dialog (convenience function)
-- @param offline_count number Count of offline media files
-- @param callback function(config) Called with configuration when user clicks "Relink"
function M.show(offline_count, callback)
    local dialog = M.create_dialog(offline_count, callback)
    qt.SHOW_DIALOG(dialog)
end

return M
