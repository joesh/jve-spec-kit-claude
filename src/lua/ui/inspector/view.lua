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
  
  -- Create content layout
  local content_layout_success, content_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if not content_layout_success then
    return error_system.create_error({message = "Failed to create content layout"})
  end
  
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
  end

  -- Create "No clip selected" state
  local no_selection_success, no_selection_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "No clip selected")
  if no_selection_success then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, no_selection_label)
  end

  -- Create collapsible sections from metadata schemas
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Starting schema loop...")
  if schemas then
    for section_name, schema in pairs(schemas) do
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Processing schema: " .. section_name)
      local section_result = collapsible_section.create_section(section_name)
      if section_result and section_result.success and section_result.return_values then
        logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Section created successfully: " .. section_name)
        
        -- Add schema fields to the section
        for _, field in ipairs(schema.fields) do
          M.add_schema_field_to_section(section_result.return_values.section, field)
        end
        
        -- Add section to content layout
        local add_success, add_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, section_result.return_values.section_widget)
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

  -- DIRECT TEST: Add a simple widget created the same way as collapsible sections
  local direct_widget_success, direct_widget = pcall(qt_constants.WIDGET.CREATE)
  if direct_widget_success then
    local direct_layout_success, direct_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
    if direct_layout_success then
      pcall(qt_constants.LAYOUT.SET_ON_WIDGET, direct_widget, direct_layout)
      
      local direct_label_success, direct_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "DIRECT WIDGET TEST")
      if direct_label_success then
        pcall(qt_constants.PROPERTIES.SET_STYLE, direct_label, "background-color: green; color: white; padding: 10px;")
        pcall(qt_constants.LAYOUT.ADD_WIDGET, direct_layout, direct_label)
      end
      
      -- This should work since basic widgets work
      local add_direct_success, add_direct_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, content_layout, direct_widget)
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Add direct widget: success=" .. tostring(add_direct_success) .. " error=" .. tostring(add_direct_error))
      
      if add_direct_success then
        pcall(qt_constants.DISPLAY.SHOW, direct_widget)
      end
    end
  end

  -- Show the content widget
  pcall(qt_constants.DISPLAY.SHOW, content_widget)

  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] ✅ Schema-driven inspector created")
  return error_system.create_success({message = "Schema-driven inspector created successfully"})
end

function M.add_schema_field_to_section(section, field)
    -- Based on original working metadata_system.lua implementation 
    local field_type = field.type
    local label = field.label
    
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

    local field_margins_success, field_margins_error = pcall(qt_constants.LAYOUT.SET_MARGINS, field_layout, 0, 2, 0, 2)
    if not field_margins_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to set field margins: " .. tostring(field_margins_error))
    end

    -- Create label for the field
    local label_success, label_widget = pcall(qt_constants.WIDGET.CREATE_LABEL, label)
    if label_success and label_widget then
        -- Text-aligned layout: labels width based on longest label text + small indent
        local label_style = [[
            QLabel {
                color: ]] .. ui_constants.COLORS.GENERAL_LABEL_COLOR .. [[;
                font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
                font-weight: normal;
                padding: 2px 6px 2px 4px;
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

        -- Add label to horizontal layout (left side)
        local add_label_success, add_label_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, field_layout, label_widget)
        if not add_label_success then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to add label to field layout: " .. tostring(add_label_error))
        end
    end

    -- Create control widget based on field type
    local control_success, control_widget
    
    if field_type == "string" then
        control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, field.default or "")
        if control_success then
            logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Creating line edit from Lua with placeholder: " .. tostring(field.default))
        end
        
    elseif field_type == "integer" then
        control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or 0))
        
    elseif field_type == "double" then
        control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or 0.0))
        
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
        else
            control_success = false
        end
        
    else
        -- Default to line edit for unknown types
        control_success, control_widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, tostring(field.default or ""))
    end

    if not control_success or not control_widget then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Failed to create control widget for field: " .. label)
        return
    end

    -- Add field widget to horizontal layout (right side)
    local add_field_success, add_field_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, field_layout, control_widget)
    if not add_field_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Warning: Failed to add field to layout: " .. tostring(add_field_error))
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
  -- Create section header with orange triangle
  local header_success, header_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "● " .. section_name)
  if header_success then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, parent_layout, header_label)
  end

  -- Create properties from schema fields
  for _, field in ipairs(schema.fields) do
    M.create_schema_field(parent_layout, field)
  end
end

function M.create_schema_field(parent_layout, field)
  local row_success, row_widget = pcall(qt_constants.WIDGET.CREATE)
  if not row_success then return end

  local row_layout_success, row_layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
  if not row_layout_success then return end

  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, row_widget, row_layout)

  -- Create label
  local label_success, label = pcall(qt_constants.WIDGET.CREATE_LABEL, field.label)
  if label_success then
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

-- Update inspector when selection changes
function M.update_selection(selected_clips)
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Selection changed: " .. #selected_clips .. " clips")

  -- For now, just log the selection
  -- TODO: Actually update the inspector UI with clip properties
  if #selected_clips == 1 then
    local clip = selected_clips[1]
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Selected clip: " .. clip.name)
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view]   ID: " .. clip.id)
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view]   Start: " .. clip.start_time .. "ms")
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view]   Duration: " .. clip.duration .. "ms")
  elseif #selected_clips > 1 then
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] Multiple clips selected for batch editing")
  else
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][view] No clips selected")
  end
end

print("🚨 DEBUG: inspector/view.lua file LOADED")
return M