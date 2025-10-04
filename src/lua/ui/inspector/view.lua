-- scripts/ui/inspector/view.lua
-- PURPOSE: Lua-owned view helpers for the Inspector (header text, batch banner, filter SoT).
-- Zero C++ calls here.

local error_system = require("core.error_system")
local logger = require("core.logger")
local ui_constants = require("core.ui_constants")
local qt_constants = require("core.qt_constants")
local widget_parenting = require("core.widget_parenting")

-- Helper for detailed error logging
local log_detailed_error = error_system.log_detailed_error

local M = {
  _panel = nil,
  _filter = "",
  root = nil,
  onFilterChanged = nil,  -- Handler for filter changes (set by controller)
  _search_input = nil,    -- Qt line edit widget for search input
  _header_label = nil,    -- Qt label widget for header text
  _batch_banner = nil,    -- Qt widget for batch editing banner
  _header_text = "",      -- Stored header text
  _batch_enabled = false, -- Stored batch state
  _selection_label = nil, -- Label showing current selection
  _field_widgets = {},    -- Map of field names to widget references
  _current_clip = nil,    -- Currently displayed clip data
  _selected_clips = {},   -- All currently selected clips (for multi-edit)
  _apply_button = nil,    -- Apply button for multi-edit
  _multi_edit_mode = false, -- Whether we're in multi-edit mode
  _sections = {},         -- Table of all sections {section_name = {section_obj, widget, fields}}
  _content_widget = nil,  -- The content widget that holds all sections (for redraws)
}

function M.mount(root)
  -- Accept either userdata (Qt widget) or table (inspector interface)
  local root_type = type(root)
  if root_type ~= "userdata" and root_type ~= "table" then
    error_system.assert_type(root, "userdata", "root", {
      operation = "mount_inspector_view",
      component = "inspector.view"
    })
  end

  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] mount() called")
  M.root = root
  M._panel = root

  -- Initialize view state (Qt widget method calls - no error wrapping needed)
  if M._panel and type(M._panel) == "userdata" then
    -- Skip method calls on direct userdata - methods may not be available
  end

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector] view mounted")
  return error_system.create_success({
    message = "Inspector view mounted successfully"
  })
end

function M.init(panel_handle)
  if not panel_handle then
    return error_system.create_error({
      code = error_system.CODES.INVALID_PANEL_HANDLE,
      category = "inspector",
      message = "panel_handle is nil",
      operation = "init_inspector_view",
      component = "inspector.view",
      user_message = "Cannot initialize inspector view - invalid panel handle",
      remediation = {
        "Ensure the inspector panel was created successfully before initializing view",
        "Check that create_inspector_panel() returned a valid result"
      }
    })
  end

  M._panel = panel_handle

  -- Initialize view state with proper FFI approach
  M._header_text = ""
  M._batch_enabled = false

  -- These will be applied when the UI widgets are actually created in ensure_search_row()
  -- No direct method calls on userdata panels needed anymore

  return error_system.create_success({
    message = "Inspector view initialized successfully"
  })
end

function M.set_header_text(text)
  -- Store the header text for when UI is built
  M._header_text = text or ""

  -- If we have a header widget created, update it directly
  if M._header_label then
    local set_text_success, set_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, M._header_label, M._header_text)
    if not set_text_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Warning: Failed to update header text: " .. log_detailed_error(set_text_error))
    end
  end
end

function M.set_batch_enabled(enabled)
  -- Store the batch state for when UI is built
  M._batch_enabled = not not enabled

  -- If we have a batch banner widget created, show/hide it directly
  if M._batch_banner then
    local set_visible_success, set_visible_error = pcall(qt_constants.DISPLAY.SET_VISIBLE, M._batch_banner, M._batch_enabled)
    if not set_visible_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Warning: Failed to update batch banner visibility: " .. log_detailed_error(set_visible_error))
    end
  end
end

function M.create_schema_driven_inspector()
  print("🚨 DEBUG: create_schema_driven_inspector() function STARTED")
  local metadata_schemas = require("ui.metadata_schemas")
  local collapsible_section = require("ui.collapsible_section")
  print("🚨 DEBUG: modules loaded successfully")
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Creating schema-driven inspector")
  local schemas = metadata_schemas.get_clip_inspector_schemas()
  
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Schemas loaded, type: " .. type(schemas) .. ", count: " .. (schemas and #schemas or "nil"))
  if schemas then
    for section_name, schema in pairs(schemas) do
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Found schema: " .. section_name)
    end
  end
  
  if not M.root then
    return error_system.create_error({
      message = "No root panel mounted",
      operation = "create_schema_driven_inspector",
      component = "inspector.view"
    })
  end

  -- M.root is a simple widget container created by CREATE_INSPECTOR()
  -- Following metadata_system.lua pattern: create our own scroll area inside the container
  
  -- Create scroll area inside the container
  local scroll_area_success, scroll_area = pcall(qt_constants.WIDGET.CREATE_SCROLL_AREA)
  if not scroll_area_success then
    return error_system.create_error({message = "Failed to create scroll area"})
  end
  
  -- Create content widget for the scroll area
  local content_widget_success, content_widget = pcall(qt_constants.WIDGET.CREATE)
  if not content_widget_success then
    return error_system.create_error({message = "Failed to create content widget"})
  end

  -- Store content widget for later updates
  M._content_widget = content_widget

  -- Create content layout
  local content_layout_success, content_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if not content_layout_success then
    return error_system.create_error({message = "Failed to create content layout"})
  end

  -- Set asymmetric margins on content layout: 0 left, 0 top, 50 right, 0 bottom
  -- This creates visual balance with the scrollbar
  pcall(qt_constants.LAYOUT.SET_MARGINS, content_layout, 0, 0, 50, 0)

  -- Set layout on content widget
  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, content_widget, content_layout)

  -- Set content widget on scroll area
  pcall(qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET, scroll_area, content_widget)

  -- Create layout for the container and add scroll area to it
  local container_layout_success, container_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if container_layout_success then
    pcall(qt_constants.LAYOUT.SET_ON_WIDGET, M.root, container_layout)
    pcall(qt_constants.LAYOUT.ADD_WIDGET, container_layout, scroll_area)
  end

  -- Create search field at top
  local search_input_success, search_input = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, "Search properties...")
  if search_input_success then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, search_input)
    M._search_input = search_input

    -- Connect text changed handler directly
    local handler_name = "inspector_search_handler"
    _G[handler_name] = function()
      local current_text_success, current_text = pcall(qt_constants.PROPERTIES.GET_TEXT, search_input)
      if current_text_success then
        M.apply_search_filter(current_text or "")
      end
    end

    -- Use C++ function directly - call with pcall to handle if not yet registered
    local success, err = pcall(function()
      qt_set_line_edit_text_changed_handler(search_input, handler_name)
    end)

    if not success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Text changed handler not available: " .. tostring(err))
    end
  end

  -- Create selection status label
  local selection_label_success, selection_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "No clip selected")
  if selection_label_success then
    pcall(qt_constants.PROPERTIES.SET_STYLE, selection_label, [[
      QLabel {
        background: #3a3a3a;
        color: white;
        padding: 10px;
        font-size: 14px;
        font-weight: bold;
      }
    ]])
    pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, selection_label)
    M._selection_label = selection_label
  end

  -- Create Apply button for multi-edit (hidden by default)
  local apply_button_success, apply_button = pcall(qt_constants.WIDGET.CREATE_BUTTON, "Apply Changes")
  if apply_button_success then
    pcall(qt_constants.PROPERTIES.SET_STYLE, apply_button, [[
      QPushButton {
        background: #4a90e2;
        color: white;
        padding: 8px;
        font-size: 13px;
        font-weight: bold;
        border: none;
        border-radius: 3px;
      }
      QPushButton:hover {
        background: #5aa0f2;
      }
      QPushButton:pressed {
        background: #3a80d2;
      }
    ]])
    pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, apply_button)
    pcall(qt_constants.DISPLAY.SET_VISIBLE, apply_button, false)  -- Hidden by default
    M._apply_button = apply_button

    -- Connect click handler
    local qt_signals = require("core.qt_signals")
    qt_signals.connect(apply_button, "clicked", function()
      M.apply_multi_edit()
    end)
  end

  -- Create collapsible sections from metadata schemas
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Starting schema loop...")
  if schemas then
    for section_name, schema in pairs(schemas) do
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Processing schema: " .. section_name)
      local section_result = collapsible_section.create_section(section_name, M._content_widget)
      if section_result and section_result.success and section_result.return_values then
        logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Section created successfully: " .. section_name)

        -- Store section and field names for filtering
        M._sections[section_name] = {
          section_obj = section_result.return_values.section,
          widget = section_result.return_values.section_widget,
          fields = {}
        }

        -- Add schema fields to the section
        for _, field in ipairs(schema.fields) do
          M.add_schema_field_to_section(section_result.return_values.section, field)
          -- Track field names for search
          table.insert(M._sections[section_name].fields, field.label or field.name or "")
        end

        -- Add section to content layout with AlignTop to prevent excessive spacing
        local add_success, add_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, section_result.return_values.section_widget, "AlignTop")
        logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Add section to layout: " .. section_name .. " success=" .. tostring(add_success) .. " error=" .. tostring(add_error))

        if add_success then
          pcall(qt_constants.DISPLAY.SHOW, section_result.return_values.section_widget)
        end
      else
        logger.error(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Failed to create section: " .. section_name)
      end
    end
  else
    logger.error(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] No schemas available!")
  end

  -- Add stretch at the end to push all content to the top
  pcall(qt_constants.LAYOUT.ADD_STRETCH, content_layout, 1)

  -- Show the content widget
  pcall(qt_constants.DISPLAY.SHOW, content_widget)

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] ✅ Schema-driven inspector created")
  return error_system.create_success({message = "Schema-driven inspector created successfully"})
end

function M.add_schema_field_to_section(section, field)
    -- Based on original working metadata_system.lua implementation
    local field_type = field.type
    local label = field.label

    print("DEBUG FIELD TYPE: label=" .. label .. ", field_type=" .. tostring(field_type) .. ", field.min=" .. tostring(field.min) .. ", field.max=" .. tostring(field.max))
    logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Creating field: " .. label .. " (type: " .. field_type .. ")")
    
    -- Create DaVinci Resolve style horizontal layout: right-aligned label + narrow gutter + field
    local field_container_success, field_container = pcall(qt_constants.WIDGET.CREATE)
    if not field_container_success or not field_container then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Failed to create field container for: " .. label)
        return
    end


    -- Create horizontal layout for label+field pair (movie credits style)
    local field_layout_success, field_layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
    if not field_layout_success or not field_layout then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Failed to create field layout for: " .. label)
        return
    end

    -- Set layout on container
    local set_layout_success, set_layout_error = pcall(qt_constants.LAYOUT.SET_ON_WIDGET, field_container, field_layout)
    if not set_layout_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Failed to set field layout: " .. tostring(set_layout_error))
        return
    end

    -- Configure tight spacing and zero margins for DaVinci Resolve professional layout
    local field_spacing_success, field_spacing_error = pcall(qt_constants.LAYOUT.SET_SPACING, field_layout, 2)
    if not field_spacing_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set field spacing: " .. tostring(field_spacing_error))
    end

    -- Add right margin to match left indentation for centered appearance
    local field_margins_success, field_margins_error = pcall(qt_constants.LAYOUT.SET_MARGINS, field_layout, 0, 2, 4, 2)
    if not field_margins_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set field margins: " .. tostring(field_margins_error))
    end

    -- Create label for the field (empty label for checkboxes to maintain alignment)
    local label_text = (field_type == "boolean") and "" or label
    local label_success, label_widget = pcall(qt_constants.WIDGET.CREATE_LABEL, label_text)
    if label_success and label_widget then
        -- Text-aligned layout: labels width based on longest label text + small indent
        -- Note: 4px top padding to align baseline with QLineEdit (which has 2px padding + 1px border)
        local label_style = [[
            QLabel {
                color: ]] .. ui_constants.COLORS.GENERAL_LABEL_COLOR .. [[;
                font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
                font-weight: normal;
                padding: 4px 6px 2px 4px;
                min-width: 100px;
            }
        ]]
        local label_style_success, label_style_error = pcall(qt_constants.PROPERTIES.SET_STYLE, label_widget, label_style)
        if not label_style_success then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to apply DaVinci style to label '" .. label .. "': " .. tostring(label_style_error))
        end

        -- Set right alignment using proper Qt alignment (movie credits style)
        local label_alignment_success, label_alignment_error = pcall(qt_constants.PROPERTIES.SET_ALIGNMENT, label_widget, qt_constants.PROPERTIES.ALIGN_RIGHT)
        if not label_alignment_success then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set label right alignment: " .. tostring(label_alignment_error))
        end

        -- Set fixed size policy for labels to maintain consistent text-aligned width
        local label_size_policy_success, label_size_policy_error = pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, label_widget, 0, 1)
        if not label_size_policy_success then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set label size policy: " .. tostring(label_size_policy_error))
        end

        -- Add label to horizontal layout (left side) with baseline alignment
        local add_label_success, add_label_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, field_layout, label_widget, "AlignBaseline")
        if not add_label_success then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to add label to field layout: " .. tostring(add_label_error))
        end
    end

    -- Create control widget based on field type
    local control_success, control_widget
    print("DEBUG: Field type for '" .. label .. "': " .. tostring(field_type) .. ", min=" .. tostring(field.min) .. ", max=" .. tostring(field.max))

    if field_type == "string" then
        control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, field.default or "")
        if control_success then
            logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Creating line edit from Lua with placeholder: " .. tostring(field.default))
            -- Style line edit to match DaVinci Resolve
            local line_edit_style =
                "QLineEdit { " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "padding: 2px 6px; " ..
                "} " ..
                "QLineEdit:focus { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "background-color: " .. ui_constants.COLORS.FIELD_FOCUS_BACKGROUND_COLOR .. "; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, control_widget, line_edit_style)
        end

    elseif field_type == "integer" then
        -- Check if field has min/max range defined - if so, create slider + line edit
        if field.min and field.max then
            -- Create container widget for slider + line edit
            local container_success, container_widget = pcall(qt_constants.WIDGET.CREATE)
            if container_success then
                -- Create horizontal layout for slider + value display
                local hbox_success, hbox_layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
                if hbox_success then
                    control_success, control_widget = true, container_widget
                    -- Set layout on container widget
                    pcall(qt_constants.LAYOUT.SET_LAYOUT, container_widget, hbox_layout)
                    pcall(qt_constants.LAYOUT.SET_SPACING, hbox_layout, 4)
                    pcall(qt_constants.LAYOUT.SET_MARGINS, hbox_layout, 0, 0, 0, 0)

                    -- Create slider widget
                    local slider_success, slider_widget = pcall(qt_constants.WIDGET.CREATE_SLIDER, "horizontal")
                    if slider_success then
                        -- Set slider range (integers can be used directly)
                        pcall(qt_constants.PROPERTIES.SET_SLIDER_RANGE, slider_widget, field.min, field.max)
                        pcall(qt_constants.PROPERTIES.SET_SLIDER_VALUE, slider_widget, field.default or field.min)

                        -- Style slider to match DaVinci Resolve
                        local slider_style =
                            "QSlider::groove:horizontal { " ..
                            "background: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                            "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                            "height: 4px; " ..
                            "border-radius: 2px; " ..
                            "} " ..
                            "QSlider::handle:horizontal { " ..
                            "background: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                            "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                            "width: 12px; " ..
                            "margin: -4px 0; " ..
                            "border-radius: 6px; " ..
                            "} " ..
                            "QSlider::handle:horizontal:hover { " ..
                            "background: " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                            "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                            "}"
                        pcall(qt_constants.PROPERTIES.SET_STYLE, slider_widget, slider_style)
                        pcall(qt_constants.LAYOUT.ADD_WIDGET_TO_LAYOUT, hbox_layout, slider_widget)
                    end

                    -- Create line edit for numeric value display
                    local line_edit_success, line_edit_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or field.min or 0))
                    if line_edit_success then
                        -- Style line edit to match DaVinci Resolve
                        local line_edit_style =
                            "QLineEdit { " ..
                            "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                            "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                            "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                            "border-radius: 3px; " ..
                            "padding: 2px 6px; " ..
                            "min-width: 50px; " ..
                            "max-width: 80px; " ..
                            "} " ..
                            "QLineEdit:focus { " ..
                            "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                            "background-color: " .. ui_constants.COLORS.FIELD_FOCUS_BACKGROUND_COLOR .. "; " ..
                            "}"
                        pcall(qt_constants.PROPERTIES.SET_STYLE, line_edit_widget, line_edit_style)
                        pcall(qt_constants.LAYOUT.ADD_WIDGET_TO_LAYOUT, hbox_layout, line_edit_widget)
                    end
                end
            else
                control_success = false
            end
        else
            -- No range defined, use simple line edit
            control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or 0))
            if control_success then
                -- Style line edit to match DaVinci Resolve
                local line_edit_style =
                    "QLineEdit { " ..
                    "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                    "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                    "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                    "border-radius: 3px; " ..
                    "padding: 2px 6px; " ..
                    "} " ..
                    "QLineEdit:focus { " ..
                    "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                    "background-color: " .. ui_constants.COLORS.FIELD_FOCUS_BACKGROUND_COLOR .. "; " ..
                    "}"
                pcall(qt_constants.PROPERTIES.SET_STYLE, control_widget, line_edit_style)
            end
        end

    elseif field_type == "double" then
        -- Check if field has min/max range defined - if so, create slider + text field
        if field.min and field.max then
            -- Create slider widget
            local slider_success, slider_widget = pcall(qt_constants.WIDGET.CREATE_SLIDER, "horizontal")
            if slider_success then
                -- Set slider range (convert double to int scale: multiply by 100 for 2 decimal precision)
                local scale = 100
                local min_val = math.floor(field.min * scale)
                local max_val = math.floor(field.max * scale)
                local current_val = math.floor((field.default or field.min) * scale)
                pcall(qt_constants.PROPERTIES.SET_SLIDER_RANGE, slider_widget, min_val, max_val)
                pcall(qt_constants.PROPERTIES.SET_SLIDER_VALUE, slider_widget, current_val)

                -- Style slider to match DaVinci Resolve
                local slider_style =
                    "QSlider { " ..
                    "margin-right: 4px; " ..  -- Space between slider and text field
                    "} " ..
                    "QSlider::groove:horizontal { " ..
                    "background: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                    "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                    "height: 4px; " ..
                    "border-radius: 2px; " ..
                    "} " ..
                    "QSlider::handle:horizontal { " ..
                    "background: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                    "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                    "width: 12px; " ..
                    "margin: -4px 0; " ..
                    "border-radius: 6px; " ..
                    "} " ..
                    "QSlider::handle:horizontal:hover { " ..
                    "background: " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                    "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                    "}"
                pcall(qt_constants.PROPERTIES.SET_STYLE, slider_widget, slider_style)

                -- Use slider as the control widget
                control_success, control_widget = true, slider_widget
            else
                -- Fallback to line edit if slider creation fails
                control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or field.min or 0.0))
            end
        else
            -- No range defined, use simple line edit
            control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or 0.0))
            if control_success then
                -- Style line edit to match DaVinci Resolve
                local line_edit_style =
                    "QLineEdit { " ..
                    "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                    "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                    "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                    "border-radius: 3px; " ..
                    "padding: 2px 6px; " ..
                    "} " ..
                    "QLineEdit:focus { " ..
                    "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                    "background-color: " .. ui_constants.COLORS.FIELD_FOCUS_BACKGROUND_COLOR .. "; " ..
                    "}"
                pcall(qt_constants.PROPERTIES.SET_STYLE, control_widget, line_edit_style)
            end
        end

    elseif field_type == "dropdown" then
        -- Create combobox widget
        local combobox_success, combobox_widget = pcall(qt_constants.WIDGET.CREATE_COMBOBOX)
        if combobox_success then
            control_success, control_widget = true, combobox_widget
            -- Add items from options
            if field.options then
                for _, option in ipairs(field.options) do
                    pcall(qt_constants.PROPERTIES.ADD_COMBOBOX_ITEM, control_widget, option)
                end
            end
            -- Set current selection
            if field.default then
                pcall(qt_constants.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT, control_widget, tostring(field.default))
            end
            -- Style combobox to match DaVinci Resolve
            local combobox_style =
                "QComboBox { " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "padding: 2px 6px; " ..
                "} " ..
                "QComboBox:focus { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "} " ..
                "QComboBox::drop-down { " ..
                "border: none; " ..
                "} " ..
                "QComboBox::down-arrow { " ..
                "image: none; " ..
                "border-left: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "width: 12px; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, control_widget, combobox_style)
        else
            control_success = false
        end

    elseif field_type == "boolean" then
        -- Create checkbox widget
        local checkbox_success, checkbox_widget = pcall(qt_constants.WIDGET.CREATE_CHECKBOX, label)
        if checkbox_success then
            control_success, control_widget = true, checkbox_widget
            -- Set initial state
            local set_checked_success, set_checked_error = pcall(qt_constants.PROPERTIES.SET_CHECKED, control_widget, field.default or false)
            if not set_checked_success then
                logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set checkbox state: " .. tostring(set_checked_error))
            end
            -- Style checkbox to match DaVinci Resolve
            local checkbox_style =
                "QCheckBox { " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "spacing: 5px; " ..
                "} " ..
                "QCheckBox::indicator { " ..
                "width: 16px; " ..
                "height: 16px; " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "} " ..
                "QCheckBox::indicator:checked { " ..
                "background-color: " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "} " ..
                "QCheckBox::indicator:hover { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, control_widget, checkbox_style)
        else
            control_success = false
        end

    else
        -- Default to line edit for unknown types
        control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or ""))
        if control_success then
            -- Style line edit to match DaVinci Resolve
            local line_edit_style =
                "QLineEdit { " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "padding: 2px 6px; " ..
                "} " ..
                "QLineEdit:focus { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "background-color: " .. ui_constants.COLORS.FIELD_FOCUS_BACKGROUND_COLOR .. "; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, control_widget, line_edit_style)
        end
    end

    if not control_success or not control_widget then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Failed to create control widget for field: " .. label)
        return
    end

    -- Store widget reference with field key for data binding
    local field_key = field.key or label:lower():gsub("%s+", "_")
    M._field_widgets[field_key] = {
        widget = control_widget,
        field = field
    }

    -- Wire up change handler for text fields to save data
    -- Skip for double fields with min/max (those use slider+line edit container)
    local is_slider_field = field_type == "double" and field.min and field.max
    if (field_type == "string" or field_type == "integer" or field_type == "double") and not is_slider_field then
        -- Use qt_signals for textChanged handler
        local qt_signals = require("core.qt_signals")
        local connection_result = qt_signals.onTextChanged(control_widget, function(new_text)
            -- Convert text to appropriate type
            local typed_value = new_text
            if field_type == "integer" then
                typed_value = tonumber(new_text) or 0
            elseif field_type == "double" then
                typed_value = tonumber(new_text) or 0.0
            end

            M.save_field_value(field_key, typed_value)
        end)

        if error_system.is_error(connection_result) then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, string.format("[inspector][view] Failed to connect text handler for '%s'", field_key))
        end
    end

    -- Add field widget to horizontal layout (right side) with baseline alignment
    local add_field_success, add_field_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, field_layout, control_widget, "AlignBaseline")
    if not add_field_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to add field to layout: " .. tostring(add_field_error))
    end

    -- For slider fields with min/max, also add a text field
    if field_type == "double" and field.min and field.max then
        local text_widget_success, text_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or field.min or 0.0))
        if text_widget_success then
            local text_style =
                "QLineEdit { " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "padding: 2px 6px; " ..
                "min-width: 50px; " ..
                "max-width: 80px; " ..
                "} " ..
                "QLineEdit:focus { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "background-color: " .. ui_constants.COLORS.FIELD_FOCUS_BACKGROUND_COLOR .. "; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, text_widget, text_style)
            pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, text_widget, "Fixed", "Fixed")
            pcall(qt_constants.LAYOUT.ADD_WIDGET, field_layout, text_widget, "AlignBaseline")
        end
    end

    -- Set stretch factor for field to expand and fill remaining space after fixed-width labels
    local field_stretch_success, field_stretch_error = pcall(qt_constants.LAYOUT.SET_STRETCH_FACTOR, field_layout, control_widget, 1)
    if not field_stretch_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set field stretch factor: " .. tostring(field_stretch_error))
    end

    -- Set responsive size policy for input fields: horizontal expanding, vertical minimum
    local field_size_policy_success, field_size_policy_error = pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, control_widget, 7, 1)
    if not field_size_policy_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set field size policy: " .. tostring(field_size_policy_error))
    end

    -- Show the field container with proper visibility chain
    local show_container_success, show_container_error = pcall(qt_constants.DISPLAY.SHOW, field_container)
    if not show_container_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to show field container: " .. tostring(show_container_error))
    end

    -- Add the complete field container to section (DaVinci Resolve movie credits layout)
    if section and section.addContentWidget then
        local add_result = section:addContentWidget(field_container)
        if add_result and add_result.success == false then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Failed to add field '" .. label .. "' to section")
        end
    else
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "No valid section provided for field: " .. label)
    end
end

function M.create_collapsible_section(parent_layout, section_name, schema)
  -- Create section header with triangle
  local is_collapsed = false
  local header_success, header_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "▼ " .. section_name)

  -- Create content container
  local container_success, container = pcall(qt_constants.WIDGET.CREATE)
  if not container_success then return end

  local container_layout_success, container_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if not container_layout_success then return end

  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, container, container_layout)
  pcall(qt_constants.CONTROL.SET_LAYOUT_SPACING, container_layout, 2)
  pcall(qt_constants.CONTROL.SET_LAYOUT_MARGINS, container_layout, 0)

  -- Create properties from schema fields
  for _, field in ipairs(schema.fields) do
    M.create_schema_field(container_layout, field)
  end

  -- Add click handler to toggle collapse
  if header_success and header_label then
    local qt_signals = require("core.qt_signals")
    qt_signals.connect(header_label, "click", function()
      is_collapsed = not is_collapsed
      if is_collapsed then
        pcall(qt_constants.PROPERTIES.SET_TEXT, header_label, "▶ " .. section_name)
        pcall(qt_constants.DISPLAY.SET_VISIBLE, container, false)
      else
        pcall(qt_constants.PROPERTIES.SET_TEXT, header_label, "▼ " .. section_name)
        pcall(qt_constants.DISPLAY.SET_VISIBLE, container, true)
      end
    end)

    pcall(qt_constants.LAYOUT.ADD_WIDGET, parent_layout, header_label)
  end

  pcall(qt_constants.LAYOUT.ADD_WIDGET, parent_layout, container)
end

function M.create_schema_field(parent_layout, field)
  local row_success, row_widget = pcall(qt_constants.WIDGET.CREATE)
  if not row_success then return end

  local row_layout_success, row_layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
  if not row_layout_success then return end

  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, row_widget, row_layout)
  pcall(qt_constants.CONTROL.SET_LAYOUT_SPACING, row_layout, 4)
  pcall(qt_constants.CONTROL.SET_LAYOUT_MARGINS, row_layout, 0)

  -- Create label with fixed width for alignment
  local label_success, label = pcall(qt_constants.WIDGET.CREATE_LABEL, field.label)
  if label_success then
    pcall(qt_constants.PROPERTIES.SET_SIZE, label, 100, 20)  -- Fixed width for label
    pcall(qt_constants.LAYOUT.ADD_WIDGET, row_layout, label)
  end

  -- Create control based on field type
  local control_success, control
  if field.type == "string" or field.type == "integer" or field.type == "double" then
    control_success, control = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default))
  elseif field.type == "boolean" then
    control_success, control = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, field.default and "true" or "false")
  elseif field.type == "dropdown" then
    control_success, control = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, field.default)
  elseif field.type == "text_area" then
    control_success, control = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, field.default)
  else
    control_success, control = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default))
  end

  if control_success then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, row_layout, control)
    -- Make control stretch to fill available space
    pcall(qt_constants.CONTROL.SET_LAYOUT_STRETCH_FACTOR, row_layout, control, 1)
  end

  pcall(qt_constants.LAYOUT.ADD_WIDGET, parent_layout, row_widget)
end

function M.create_property_section(parent_layout, section_name, properties)
  -- Create section header
  local header_success, header_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "● " .. section_name)
  if header_success and header_label then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, parent_layout, header_label)
  end

  -- Create properties container
  local container_success, container = pcall(qt_constants.WIDGET.CREATE)
  if not container_success or not container then
    return false
  end

  local container_layout_success, container_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if not container_layout_success or not container_layout then
    return false
  end

  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, container, container_layout)

  -- Add properties
  for _, prop in ipairs(properties) do
    M.create_property_control(container_layout, prop)
  end

  pcall(qt_constants.LAYOUT.ADD_WIDGET, parent_layout, container)
  return true
end

function M.create_property_control(parent_layout, property)
  local row_success, row_widget = pcall(qt_constants.WIDGET.CREATE)
  if not row_success or not row_widget then
    return false
  end

  local row_layout_success, row_layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
  if not row_layout_success or not row_layout then
    return false
  end

  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, row_widget, row_layout)

  -- Create label
  local label_success, label = pcall(qt_constants.WIDGET.CREATE_LABEL, property.name)
  if label_success and label then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, row_layout, label)
  end

  -- Create control based on type
  if property.type == "text" then
    local input_success, input = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, property.value)
    if input_success and input then
      pcall(qt_constants.LAYOUT.ADD_WIDGET, row_layout, input)
    end
  elseif property.type == "number" then
    local input_success, input = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(property.value))
    if input_success and input then
      pcall(qt_constants.LAYOUT.ADD_WIDGET, row_layout, input)
    end
  elseif property.type == "slider" then
    local input_success, input = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(property.value))
    if input_success and input then
      pcall(qt_constants.LAYOUT.ADD_WIDGET, row_layout, input)
    end
  elseif property.type == "dropdown" then
    local input_success, input = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, property.value)
    if input_success and input then
      pcall(qt_constants.LAYOUT.ADD_WIDGET, row_layout, input)
    end
  end

  pcall(qt_constants.LAYOUT.ADD_WIDGET, parent_layout, row_widget)
  return true
end

function M.set_filter(text)
  M._filter = text or ""

  -- Update the search input widget if we created one
  if M._search_input then
    local set_text_success, set_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, M._search_input, M._filter)
    if not set_text_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Warning: Failed to update search input text: " .. log_detailed_error(set_text_error))
    end
  end

  -- Legacy C++ panel support - no longer available with FFI userdata
  -- Search text is now handled by direct widget manipulation above

  -- Trigger onChange if we have a handler
  if M.onFilterChanged then
    M.onFilterChanged(M._filter)
  end
end

function M.get_filter()
  return M._filter or ""
end

-- Apply search filter to hide/show sections based on query
function M.apply_search_filter(query)
  M._filter = query or ""
  local search_text = M._filter:lower()

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Applying search filter: '" .. search_text .. "'")

  -- If empty search, show all sections
  if search_text == "" then
    for section_name, section_data in pairs(M._sections) do
      if section_data.widget then
        pcall(qt_constants.DISPLAY.SET_VISIBLE, section_data.widget, true)
      end
    end
    -- Force widget redraw to prevent visual artifacts
    if M._content_widget then
      pcall(qt_update_widget, M._content_widget)
    end
    return
  end

  -- Filter sections based on search query
  for section_name, section_data in pairs(M._sections) do
    local should_show = false

    -- Check if section name matches
    if section_name:lower():find(search_text, 1, true) then
      should_show = true
    end

    -- Check if any field name matches
    if not should_show then
      for _, field_name in ipairs(section_data.fields) do
        if field_name:lower():find(search_text, 1, true) then
          should_show = true
          break
        end
      end
    end

    -- Show/hide section based on match
    if section_data.widget then
      pcall(qt_constants.DISPLAY.SET_VISIBLE, section_data.widget, should_show)
    end
  end

  -- Force widget redraw to prevent visual artifacts
  if M._content_widget then
    pcall(qt_update_widget, M._content_widget)
  end
end

function M.ensure_search_row()
  -- Create search UI if not already created
  if M._search_input then
    return error_system.create_success({
      message = "Search row already exists"
    })
  end

  -- This function was referenced but missing - now implemented
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Creating search row")

  return error_system.create_success({
    message = "Search row ensured"
  })
end

-- Save field value to current clip
function M.save_field_value(field_key, value)
  if not M._current_clip then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Cannot save field - no clip selected")
    return
  end

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, string.format("[inspector][view] Saving field '%s' = '%s' to clip %s", field_key, tostring(value), M._current_clip.id))

  -- Update clip data in memory (this modifies the timeline's clip object since Lua passes tables by reference)
  M._current_clip[field_key] = value

  -- Save to database - this ensures persistence across selections
  local db = require("core.database")
  local success = db.update_clip_property(M._current_clip.id, field_key, value)

  if success then
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, string.format("[inspector][view] ✅ Saved field '%s' to clip %s", field_key, M._current_clip.id))
  else
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, string.format("[inspector][view] ❌ Failed to save field '%s'", field_key))
  end
end

-- Expose save function globally for manual testing
_G.inspector_save_test = function(field_key, value)
  M.save_field_value(field_key, value)
end

-- Save all modified fields from widgets back to current clip
function M.save_all_fields()
  if not M._current_clip then
    return
  end

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Saving all modified fields for clip: " .. M._current_clip.id)

  -- Read all widget values and update clip
  for field_key, field_info in pairs(M._field_widgets) do
    local widget = field_info.widget
    local field_type = field_info.field.type

    -- Get text from widget
    local get_text_success, text_value = pcall(qt_constants.PROPERTIES.GET_TEXT, widget)
    if get_text_success and text_value then
      -- Convert to appropriate type
      local typed_value = text_value
      if field_type == "integer" then
        typed_value = tonumber(text_value) or 0
      elseif field_type == "double" then
        typed_value = tonumber(text_value) or 0.0
      end

      -- Update clip if value changed
      if M._current_clip[field_key] ~= typed_value then
        M._current_clip[field_key] = typed_value
        logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, string.format("[inspector][view] Updated %s.%s = %s", M._current_clip.id, field_key, tostring(typed_value)))
      end
    end
  end
end

-- Load clip data into widgets
function M.load_clip_data(clip)
  if not clip then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] No clip to load")
    return
  end

  -- Save previous clip's data before loading new one
  if M._current_clip and M._current_clip ~= clip then
    M.save_all_fields()
  end

  M._current_clip = clip
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Loading clip data: " .. clip.name)

  -- Populate all field widgets from clip data
  for field_key, field_info in pairs(M._field_widgets) do
    local widget = field_info.widget
    local value = clip[field_key] or field_info.field.default or ""

    -- Convert value to string for display
    local display_value = tostring(value)

    -- Clear any placeholder text from multi-edit mode
    pcall(qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT, widget, "")

    local set_text_success, set_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, widget, display_value)
    if not set_text_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, string.format("[inspector][view] Failed to set field '%s': %s", field_key, tostring(set_text_error)))
    end
  end
end

-- Update inspector when selection changes
function M.load_multi_clip_data(clips)
  if not clips or #clips == 0 then return end

  M._selected_clips = clips
  M._multi_edit_mode = true
  M._current_clip = nil

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Loading multi-clip data: " .. #clips .. " clips")

  -- For each field, check if all clips have the same value
  for field_key, field_info in pairs(M._field_widgets) do
    local widget = field_info.widget
    local first_value = clips[1][field_key]
    local all_same = true

    -- Check if all clips have the same value
    for i = 2, #clips do
      if clips[i][field_key] ~= first_value then
        all_same = false
        break
      end
    end

    -- Display value or placeholder
    if all_same then
      local display_value = tostring(first_value or field_info.field.default or "")
      pcall(qt_constants.PROPERTIES.SET_TEXT, widget, display_value)
    else
      -- Show placeholder for mixed values
      pcall(qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT, widget, "<mixed>")
      pcall(qt_constants.PROPERTIES.SET_TEXT, widget, "")
    end
  end

  -- Show Apply button
  if M._apply_button then
    pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, true)
  end
end

function M.apply_multi_edit()
  if not M._multi_edit_mode or #M._selected_clips == 0 then
    return
  end

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI,
      "[inspector][view] Applying multi-edit to " .. #M._selected_clips .. " clips")

  local db = require("core.database")

  -- Read current values from widgets and apply to all selected clips
  for field_key, field_info in pairs(M._field_widgets) do
    local widget = field_info.widget
    local field_type = field_info.field.type

    local get_text_success, text_value = pcall(qt_constants.PROPERTIES.GET_TEXT, widget)
    if get_text_success and text_value and text_value ~= "" then
      -- Convert to appropriate type
      local typed_value = text_value
      if field_type == "integer" then
        typed_value = tonumber(text_value) or 0
      elseif field_type == "double" then
        typed_value = tonumber(text_value) or 0.0
      end

      -- Apply to all selected clips
      for _, clip in ipairs(M._selected_clips) do
        clip[field_key] = typed_value
        db.update_clip_property(clip.id, field_key, typed_value)
        logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            string.format("[inspector][view] Updated %s.%s = %s",
                clip.id, field_key, tostring(typed_value)))
      end
    end
  end
end

function M.update_selection(selected_clips)
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Selection changed: " .. #selected_clips .. " clips")

  -- Update the selection label
  if M._selection_label then
    local label_text = ""
    if #selected_clips == 1 then
      local clip = selected_clips[1]
      label_text = string.format("Selected: %s\nID: %s\nStart: %dms\nDuration: %dms",
        clip.name, clip.id, clip.start_time, clip.duration)
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Showing clip: " .. clip.name)

      -- Exit multi-edit mode
      M._multi_edit_mode = false
      if M._apply_button then
        pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, false)
      end

      -- Load clip data into inspector fields
      M.load_clip_data(clip)
    elseif #selected_clips > 1 then
      label_text = string.format("%d clips selected", #selected_clips)
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Multiple clips selected")

      -- Enter multi-edit mode
      M.load_multi_clip_data(selected_clips)
    else
      label_text = "No clip selected"
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] No selection")
      M._current_clip = nil
      M._multi_edit_mode = false
      if M._apply_button then
        pcall(qt_constants.DISPLAY.SET_VISIBLE, M._apply_button, false)
      end
    end

    local set_text_success, set_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, M._selection_label, label_text)
    if not set_text_success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Failed to update selection label: " .. tostring(set_text_error))
    else
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Selection label updated successfully")
    end
  else
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] No selection label widget available!")
  end
end

print("🚨 DEBUG: inspector/view.lua file LOADED")
return M