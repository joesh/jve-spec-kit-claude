-- Lua Implementation of CollapsibleSection
-- Matches C++ CollapsibleSection functionality for Inspector panels

local error_system = require("core.error_system")
local error_builder = require("core.error_builder")
local qt_signals = require("core.qt_signals")
local signals = require("core.signals")
local logger = require("core.logger")
local ui_constants = require("core.ui_constants")
local qt_constants = require("core.qt_constants")

-- Helper for detailed error logging
local log_detailed_error = error_system.log_detailed_error

-- Initialize logger
logger.init()

local collapsible_section = {}

-- CollapsibleSection class
local CollapsibleSection = {}
CollapsibleSection.__index = CollapsibleSection

function CollapsibleSection.new(title, expanded, parent_widget)
    local self = setmetatable({}, CollapsibleSection)

    -- State
    self.title = title
    self.expanded = expanded ~= nil and expanded or true  -- Default to expanded for now
    self.bypassed = false
    self.section_enabled = true  -- Default to enabled (red dot)

    -- Widget objects (will be set during creation)
    self.main_widget = nil
    self.header_widget = nil
    self.enabled_dot = nil
    self.title_label = nil
    self.content_frame = nil
    self.content_layout = nil
    self.disclosure_triangle = nil

    -- Parent widget for triggering layout updates
    self.parent_widget = parent_widget

    -- Signal connections for cleanup
    self.connections = {}

    -- Heights calculated dynamically based on content, no magic numbers
    -- collapsed_height determined by header widget size
    -- expanded_height determined by content layout size hint

    return self
end

function CollapsibleSection:create()
    local operation_context = {
        operation = "create_collapsible_section",
        component = "collapsible_section",
        details = { title = self.title }
    }

    -- Step 1: Create main widget container
    local main_success, main_widget = pcall(qt_constants.WIDGET.CREATE)
    if not main_success or not main_widget then
        return error_system.create_error({
            code = error_system.CODES.QT_WIDGET_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create main widget",
            operation = "create_collapsible_section",
            component = "collapsible_section",
            user_message = "Cannot create collapsible section - Qt widget creation failed",
            technical_details = {
                error = main_widget,
                title = self.title
            }
        })
    end
    self.main_widget = main_widget

    -- Step 2: Use main widget as layout container (create_vbox_layout returns widget with layout)
    -- In the FFI system, we'll use the main_widget directly as the container and add children to it

    -- Create a layout for the main widget
    local main_layout_success, main_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
    if not main_layout_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create main layout for collapsible section",
            operation = "create_collapsible_section",
            component = "collapsible_section",
            user_message = "Cannot create section layout",
            technical_details = {
                error = main_layout,
                title = self.title
            }
        })
    end
    
    -- Set the layout on the main widget
    local set_layout_success, set_layout_error = pcall(qt_constants.LAYOUT.SET_ON_WIDGET, self.main_widget, main_layout)
    if not set_layout_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_SET_FAILED,
            category = "qt_widget", 
            message = "Failed to set main layout on widget",
            operation = "create_collapsible_section",
            component = "collapsible_section",
            user_message = "Cannot set section layout",
            technical_details = {
                error = set_layout_error,
                title = self.title
            }
        })
    end
    
    -- Store the layout as our container for adding widgets
    self.layout_container = main_layout

    -- CRITICAL: Configure main section layout spacing and margins to eliminate gaps between sections
    -- Qt defaults to 9px margins which causes excessive spacing between collapsed headers
    local main_spacing_success, main_spacing_error = pcall(qt_constants.LAYOUT.SET_SPACING, main_layout, 1)
    if not main_spacing_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set main layout spacing: " .. log_detailed_error(main_spacing_error))
    end
    
    local main_margins_success, main_margins_error = pcall(qt_constants.LAYOUT.SET_MARGINS, main_layout, 0, 0, 0, 0)
    if not main_margins_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set main layout margins: " .. log_detailed_error(main_margins_error))
    end

    -- No minimum size constraints - let layout calculate size from content
    -- Our scroll area sizing fix in validateWidget() will handle proper sizing

    -- Set appropriate size policy for main widget (QSizePolicy::Expanding = 7, QSizePolicy::Minimum = 1)
    local main_size_policy_success, main_size_policy_error = pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, self.main_widget, 7, 1)
    if not main_size_policy_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set main widget size policy: " .. log_detailed_error(main_size_policy_error))
    end

    -- Apply proper section styling (with optional debug colors)
    local main_style = [[
        QWidget {
            background-color: #2b2b2b;
            margin: 0px;
            padding: 0px;
        }
    ]]
    
    -- Add debug coloring if enabled
    if ui_constants.STYLES.DEBUG_COLORS_ENABLED then
        main_style = main_style .. [[
        QWidget {
            border: 2px solid red;
        }
        ]]
    end
    
    local main_style_success, main_style_error = pcall(qt_constants.PROPERTIES.SET_STYLE, self.main_widget, main_style)
    if not main_style_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to style main widget: " .. log_detailed_error(main_style_error))
    end

    -- FIX: Make main widget visible immediately to prevent visibility warnings
    local show_main_success, show_main_error = pcall(qt_constants.DISPLAY.SHOW, self.main_widget)
    if not show_main_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to show main widget: " .. log_detailed_error(show_main_error))
    end

    -- Step 5: Create header widget (C++ line 39-40)
    local header_result = self:createHeader(operation_context)
    if error_system.is_error(header_result) then
        return header_result
    end

    -- Step 6: Create content frame (C++ line 140)
    local content_result = self:createContentFrame(operation_context)
    if error_system.is_error(content_result) then
        return content_result
    end

    -- Step 7: Add header and content to layout container (using FFI approach)
    local add_header_success, add_header_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, self.layout_container, self.header_widget)
    if not add_header_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_ADD_FAILED,
            category = "qt_widget",
            message = "Failed to add header to layout container",
            operation = "create_collapsible_section",
            component = "collapsible_section",
            user_message = "Cannot add header to section layout",
            technical_details = {
                error = add_header_error,
                container = self.layout_container,
                header = self.header_widget
            }
        })
    end

    local add_content_success, add_content_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, self.layout_container, self.content_frame)
    if not add_content_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_ADD_FAILED,
            category = "qt_widget",
            message = "Failed to add content to layout container",
            operation = "create_collapsible_section",
            component = "collapsible_section",
            user_message = "Cannot add content to section layout",
            technical_details = {
                error = add_content_error,
                container = self.layout_container,
                content = self.content_frame
            }
        })
    end

    -- Step 8: Set initial expanded state (start collapsed)
    local expand_result = self:setExpanded(false)
    if error_system.is_error(expand_result) then
        return expand_result
    end

    -- Step 9: Widgets will be shown after parenting (moved to ui_toolkit.lua after smart_add_child)
    logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "Section '" .. self.title .. "' created, visibility will be set after parenting")

    return error_system.create_success({
        message = "CollapsibleSection '" .. self.title .. "' created successfully",
        return_values = {
            section = self,  -- Return the actual CollapsibleSection object
            section_widget = self.main_widget,
            content_layout = self.content_layout
        }
    })
end

function CollapsibleSection:createHeader(operation_context)
    -- C++ lines 39-40: header widget with fixed height
    local header_success, header_widget = pcall(qt_constants.WIDGET.CREATE)
    if not header_success or not header_widget then
        return error_system.create_error({
            code = error_system.CODES.QT_WIDGET_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create header widget",
            operation = "createHeader",
            component = "collapsible_section",
            user_message = "Cannot create section header",
            technical_details = {
                error = header_widget,
                title = self.title
            }
        })
    end
    self.header_widget = header_widget

    -- Style header widget (C++ lines 41-69 with optional debug colors)
    local header_style = [[
        QWidget {
            background-color: transparent;
            border: none;
            border-top: 1px solid #000000;
        }
        QWidget:hover {
            background-color: #454545;
        }
    ]]
    
    -- Add debug coloring if enabled
    if ui_constants.STYLES.DEBUG_COLORS_ENABLED then
        header_style = header_style .. [[
        QWidget {
            border: 2px solid green;
        }
        ]]
    end
    
    local header_style_success, header_style_error = pcall(qt_constants.PROPERTIES.SET_STYLE, self.header_widget, header_style)
    if not header_style_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to style header: " .. log_detailed_error(header_style_error))
    end

    -- Create header layout (C++ lines 71-73)
    local header_layout_success, header_layout = pcall(qt_constants.LAYOUT.CREATE_HBOX)
    if not header_layout_success or not header_layout then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create header layout",
            operation = "createHeader",
            component = "collapsible_section",
            user_message = "Cannot create header layout",
            technical_details = {
                error = header_layout,
                title = self.title
            }
        })
    end

    -- Set header layout
    local set_header_layout_success, set_header_layout_error = pcall(qt_constants.LAYOUT.SET_ON_WIDGET, self.header_widget, header_layout)
    if not set_header_layout_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_SET_FAILED,
            category = "qt_widget",
            message = "Failed to set header layout",
            operation = "createHeader",
            component = "collapsible_section",
            user_message = "Cannot set header layout",
            technical_details = {
                error = set_header_layout_error,
                widget = self.header_widget,
                layout = header_layout
            }
        })
    end

    -- Configure header layout margins and spacing (C++ lines 72-73)
    local header_spacing_success, header_spacing_error = pcall(qt_constants.LAYOUT.SET_SPACING, header_layout, 1)
    if not header_spacing_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set header spacing: " .. log_detailed_error(header_spacing_error))
    end

    local header_margins_success, header_margins_error = pcall(qt_constants.LAYOUT.SET_MARGINS, header_layout, 0, 0, 0, 0)
    if not header_margins_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set header margins: " .. log_detailed_error(header_margins_error))
    end

    -- Create enabled dot (C++ lines 75-81)
    -- Disabled: orange dot not needed
    -- local dot_result = self:createEnabledDot(header_layout, operation_context)
    -- if error_system.is_error(dot_result) then
    --     return dot_result
    -- end

    -- Create disclosure triangle (C++ lines 83-87)
    local triangle_result = self:createDisclosureTriangle(header_layout, operation_context)
    if error_system.is_error(triangle_result) then
        return triangle_result
    end

    -- Create title label (C++ lines 89-91)
    local title_result = self:createTitleLabel(header_layout, operation_context)
    if error_system.is_error(title_result) then
        return title_result
    end

    -- Enable mouse events on header widget so event filter can receive clicks
    local header_hover_success, header_hover_error = pcall(qt_set_widget_attribute, self.header_widget, "WA_Hover", true)
    if not header_hover_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to enable hover on header: " .. tostring(header_hover_error))
    end

    -- Add click handler to entire header widget for expand/collapse
    local header_callback_name = "CollapsibleSection_header_toggle_" .. self.title:gsub(" ", "_")
    local header_click_success, header_click_error = pcall(qt_constants.CONTROL.SET_WIDGET_CLICK_HANDLER, self.header_widget, header_callback_name)
    if not header_click_success then
        logger.error(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] ERROR: Failed to set header click handler: " .. log_detailed_error(header_click_error))
    end

    -- Create the header click callback (same functionality as triangle)
    local section_instance = self
    _G[header_callback_name] = function()
        logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "🖱️ Header clicked for: " .. self.title)
        local result = section_instance:setExpanded(not section_instance.expanded)
        if error_system.is_error(result) then
            logger.error(ui_constants.LOGGING.COMPONENT_NAMES.UI, "❌ Header click failed: " .. error_system.format_user_error(result))
            return false
        end
        return true
    end

    return error_system.create_success({
        message = "Section header created successfully"
    })
end

function CollapsibleSection:createEnabledDot(header_layout, operation_context)
    -- C++ lines 75-81: Resolve-style enabled dot (red = enabled, gray = disabled)
    local dot_success, dot_widget = pcall(qt_constants.WIDGET.CREATE_LABEL, "●")
    if not dot_success or not dot_widget then
        return error_system.create_error({
            code = error_system.CODES.QT_WIDGET_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create enabled dot",
            operation = "createEnabledDot",
            component = "collapsible_section",
            user_message = "Cannot create section enabled indicator",
            technical_details = {
                error = dot_widget,
                title = self.title
            }
        })
    end
    self.enabled_dot = dot_widget

    -- Style the dot (C++ lines 77-80 + updateSectionEnabledDot)
    local dot_style = self.section_enabled and [[
        QLabel {
            background-color: #ff6b35;
            border: none;
            border-radius: 4px;
            max-width: 8px;
            min-width: 8px;
            max-height: 8px;
            min-height: 8px;
        }
    ]] or [[
        QLabel {
            background-color: #666666;
            border: none;
            border-radius: 4px;
            max-width: 8px;
            min-width: 8px;
            max-height: 8px;
            min-height: 8px;
        }
    ]]

    local dot_style_success, dot_style_error = pcall(qt_constants.PROPERTIES.SET_STYLE, self.enabled_dot, dot_style)
    if not dot_style_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to style enabled dot: " .. log_detailed_error(dot_style_error))
    end

    -- Make dot transparent to mouse events so clicks pass through to header widget
    local dot_attr_success, dot_attr_error = pcall(qt_set_widget_attribute, self.enabled_dot, "WA_TransparentForMouseEvents", true)
    if not dot_attr_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set transparent attribute on dot: " .. tostring(dot_attr_error))
    end

    -- Add dot to header layout (C++ line 133)
    local add_dot_success, add_dot_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, header_layout, self.enabled_dot)
    if not add_dot_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_ADD_FAILED,
            category = "qt_widget",
            message = "Failed to add dot to header layout",
            operation = "createEnabledDot",
            component = "collapsible_section",
            user_message = "Cannot add enabled indicator to header",
            technical_details = {
                error = add_dot_error,
                layout = header_layout,
                dot = self.enabled_dot
            }
        })
    end

    return error_system.create_success({
        message = "Enabled dot created successfully"
    })
end

function CollapsibleSection:createDisclosureTriangle(header_layout, operation_context)
    -- C++ lines 83-87: Disclosure triangle QLabel with Unicode triangles ▶/▼
    -- Using QLabel instead of QPushButton so clicks pass through to header widget
    local triangle_success, triangle_widget = pcall(qt_constants.WIDGET.CREATE_LABEL, "▶")
    if not triangle_success or not triangle_widget then
        return error_system.create_error({
            code = error_system.CODES.QT_WIDGET_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create disclosure triangle",
            operation = "createDisclosureTriangle",
            component = "collapsible_section",
            user_message = "Cannot create section expand/collapse button",
            technical_details = {
                error = triangle_widget,
                title = self.title
            }
        })
    end
    self.disclosure_triangle = triangle_widget

    -- Set triangle text based on expanded state (C++ line 280: "▼" : "▶")
    local triangle_text = self.expanded and "▼" or "▶"
    local set_text_success, set_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, self.disclosure_triangle, triangle_text)
    if not set_text_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set triangle text: " .. log_detailed_error(set_text_error))
    end

    -- Style disclosure triangle (C++ line 85: 16x16 fixed size)
    local triangle_style_success, triangle_style_error = pcall(qt_constants.PROPERTIES.SET_STYLE, self.disclosure_triangle, [[
        QLabel {
            background: transparent;
            border: none;
            color: ]] .. ui_constants.COLORS.LABEL_TEXT_COLOR .. [[;
            font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
            min-width: 16px;
            max-width: 16px;
            padding: 0px;
        }
    ]])
    if not triangle_style_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to style triangle: " .. log_detailed_error(triangle_style_error))
    end

    -- Triangle doesn't need its own click handler - the header widget handles all clicks

    -- Add triangle to header layout
    local add_triangle_success, add_triangle_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, header_layout, self.disclosure_triangle)
    if not add_triangle_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_ADD_FAILED,
            category = "qt_widget",
            message = "Failed to add triangle to header layout",
            operation = "createDisclosureTriangle",
            component = "collapsible_section",
            user_message = "Cannot add expand/collapse button to header",
            technical_details = {
                error = add_triangle_error,
                layout = header_layout,
                triangle = self.disclosure_triangle
            }
        })
    end

    return error_system.create_success({
        message = "Disclosure triangle created successfully"
    })
end

function CollapsibleSection:createTitleLabel(header_layout, operation_context)
    -- C++ lines 89-91: Section title
    local title_success, title_widget = pcall(qt_constants.WIDGET.CREATE_LABEL, self.title)
    if not title_success or not title_widget then
        return error_system.create_error({
            code = error_system.CODES.QT_WIDGET_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create title label",
            operation = "createTitleLabel",
            component = "collapsible_section",
            user_message = "Cannot create section title",
            technical_details = {
                error = title_widget,
                title = self.title
            }
        })
    end
    self.title_label = title_widget

    -- Set title text
    local title_text_success, title_text_error = pcall(qt_constants.PROPERTIES.SET_TEXT, self.title_label, self.title)
    if not title_text_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set title text: " .. log_detailed_error(title_text_error))
    end

    -- Style title label (C++ lines 63-68)
    local title_style_success, title_style_error = pcall(qt_constants.PROPERTIES.SET_STYLE, self.title_label, [[
        QLabel {
            color: #ffffff;
            font-weight: normal;
            font-size: ]] .. ui_constants.FONTS.HEADER_FONT_SIZE .. [[;
            background: transparent;
        }
    ]])
    if not title_style_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to style title: " .. log_detailed_error(title_style_error))
    end

    -- Make title transparent to mouse events so clicks pass through to header widget
    local attr_success, attr_error = pcall(qt_set_widget_attribute, self.title_label, "WA_TransparentForMouseEvents", true)
    if not attr_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set transparent attribute on title: " .. tostring(attr_error))
    end

    -- Add title to header layout (C++ line 134)
    local add_title_success, add_title_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, header_layout, self.title_label)
    if not add_title_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_ADD_FAILED,
            category = "qt_widget",
            message = "Failed to add title to header layout",
            operation = "createTitleLabel",
            component = "collapsible_section",
            user_message = "Cannot add title to header",
            technical_details = {
                error = add_title_error,
                layout = header_layout,
                title = self.title_label
            }
        })
    end

    return error_system.create_success({
        message = "Title label created successfully"
    })
end

function CollapsibleSection:createContentFrame(operation_context)
    -- C++ line 140: Content frame
    local content_success, content_widget = pcall(qt_constants.WIDGET.CREATE)
    if not content_success or not content_widget then
        return error_system.create_error({
            code = error_system.CODES.QT_WIDGET_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create content frame",
            operation = "createContentFrame",
            component = "collapsible_section",
            user_message = "Cannot create section content area",
            technical_details = {
                error = content_widget,
                title = self.title
            }
        })
    end
    self.content_frame = content_widget

    -- Style content frame (C++ lines 141-146 with optional debug colors)
    local content_style = [[
        QWidget {
            background-color: transparent;
            border: none;
        }
    ]]
    
    -- Add debug coloring if enabled
    if ui_constants.STYLES.DEBUG_COLORS_ENABLED then
        content_style = content_style .. [[
        QWidget {
            border: 2px solid blue;
        }
        ]]
    end
    
    local content_style_success, content_style_error = pcall(qt_constants.PROPERTIES.SET_STYLE, self.content_frame, content_style)
    if not content_style_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to style content frame: " .. log_detailed_error(content_style_error))
    end

    -- Create content layout (C++ lines 149-151)
    local content_layout_success, content_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
    if not content_layout_success or not content_layout then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_CREATION_FAILED,
            category = "qt_widget",
            message = "Failed to create content layout",
            operation = "createContentFrame",
            component = "collapsible_section",
            user_message = "Cannot create content layout",
            technical_details = {
                error = content_layout,
                title = self.title
            }
        })
    end
    self.content_layout = content_layout

    -- Set content layout
    local set_content_layout_success, set_content_layout_error = pcall(qt_constants.LAYOUT.SET_ON_WIDGET, self.content_frame, self.content_layout)
    if not set_content_layout_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_SET_FAILED,
            category = "qt_widget",
            message = "Failed to set content layout",
            operation = "createContentFrame",
            component = "collapsible_section",
            user_message = "Cannot set content layout",
            technical_details = {
                error = set_content_layout_error,
                widget = self.content_frame,
                layout = self.content_layout
            }
        })
    end

    -- Configure content layout margins and spacing (C++ lines 150-151)
    local content_spacing_success, content_spacing_error = pcall(qt_constants.LAYOUT.SET_SPACING, self.content_layout, 1)
    if not content_spacing_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set content spacing: " .. log_detailed_error(content_spacing_error))
    end

    local content_margins_success, content_margins_error = pcall(qt_constants.LAYOUT.SET_MARGINS, self.content_layout, 0, 0, 0, 0)
    if not content_margins_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set content margins: " .. log_detailed_error(content_margins_error))
    end

    -- No minimum size constraints - let layout calculate size from content
    -- Our scroll area sizing fix in validateWidget() will handle proper sizing

    -- Set appropriate size policy for expanding content (QSizePolicy::Expanding = 7, QSizePolicy::Minimum = 1)
    local size_policy_success, size_policy_error = pcall(qt_constants.GEOMETRY.SET_SIZE_POLICY, self.content_frame, 7, 1)
    if not size_policy_success then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to set content frame size policy: " .. log_detailed_error(size_policy_error))
    end

    return error_system.create_success({
        message = "Content frame created successfully"
    })
end

function CollapsibleSection:setExpanded(expanded)
    if self.expanded == expanded then
        return error_system.create_success({
            message = "Section already in desired state"
        })
    end

    self.expanded = expanded

    -- Update disclosure triangle text (C++ line 280: "▼" : "▶")
    if self.disclosure_triangle then
        local triangle_text = expanded and "▼" or "▶"
        local update_triangle_success, update_triangle_error = pcall(qt_constants.PROPERTIES.SET_TEXT, self.disclosure_triangle, triangle_text)
        if not update_triangle_success then
            logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[collapsible_section] Warning: Failed to update triangle text: " .. log_detailed_error(update_triangle_error))
        end
    end

    -- C++ lines 211-222: Set visibility and height constraints
    local visibility_success, visibility_error = pcall(qt_constants.DISPLAY.SET_VISIBLE, self.content_frame, expanded)
    if not visibility_success then
        return error_system.create_error({
            code = error_system.CODES.VISIBILITY_SET_FAILED,
            category = "qt_widget",
            message = "Failed to set content frame visibility",
            operation = "setExpanded",
            component = "collapsible_section",
            user_message = "Cannot change section visibility",
            technical_details = {
                error = visibility_error,
                widget = self.content_frame,
                expanded = expanded
            }
        })
    end

    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "📋 Section '" .. self.title .. "' " .. (expanded and "expanded" or "collapsed"))

    -- Force layout recalculation by updating both the section widget and its parent
    -- Update the section's main widget first
    if self.main_widget then
        pcall(qt_update_widget, self.main_widget)
    end

    -- Then update the parent to recalculate the overall layout
    if self.parent_widget then
        pcall(qt_update_widget, self.parent_widget)
        logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "✅ Section " .. (expanded and "expanded" or "collapsed") .. " - triggered parent layout update")
    else
        logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "⚠️ Section " .. (expanded and "expanded" or "collapsed") .. " - no parent widget for layout update")
    end

    return error_system.create_success({
        message = "Section expand state set to " .. tostring(expanded)
    })
end

function CollapsibleSection:addContentWidget(widget)
    if not self.content_layout then
        return error_system.create_error({
            code = error_system.CODES.SECTION_NOT_INITIALIZED,
            category = error_system.CATEGORIES.UI,
            message = "CollapsibleSection content layout not initialized",
            user_message = "Cannot add widget to section '" .. self.title .. "' - section not properly initialized",
            operation = "addContentWidget",
            component = "CollapsibleSection",
            technical_details = {
                section_title = self.title,
                content_layout = self.content_layout
            },
            remediation = {
                "Ensure CollapsibleSection.create() completed successfully before adding widgets",
                "Check that section creation did not fail during initialization"
            }
        })
    end

    local add_success, add_error = pcall(qt_constants.LAYOUT.ADD_WIDGET, self.content_layout, widget)
    if not add_success then
        return error_system.create_error({
            code = error_system.CODES.LAYOUT_ADD_FAILED,
            category = "qt_widget",
            message = "Failed to add widget to section content",
            operation = "addContentWidget",
            component = "CollapsibleSection",
            user_message = "Failed to add widget to section '" .. self.title .. "'",
            technical_details = {
                error = add_error,
                widget = widget,
                section_title = self.title,
                content_layout = self.content_layout
            }
        })
    end

    -- Widget visibility is managed by the layout system, no need to explicitly show
    -- (Removed SHOW_PARENTS call that was causing widgets to appear in separate windows)

    return error_system.create_success({
        message = "Widget added to section '" .. self.title .. "'"
    })
end

-- Cleanup function to disconnect signals and free resources
function CollapsibleSection:cleanup()
    -- Disconnect all signal connections
    for _, connection_id in ipairs(self.connections) do
        qt_signals.disconnect(connection_id)
    end
    self.connections = {}
    
    -- Clear widget references
    self.main_widget = nil
    self.header_widget = nil
    self.enabled_dot = nil
    self.title_label = nil
    self.content_frame = nil
    self.content_layout = nil
    self.disclosure_triangle = nil
    
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "🧹 Section cleaned up: " .. self.title)
    
    return error_system.create_success({message = "Section cleaned up successfully"})
end

-- User extension point: Hook for section state changes
-- Users can connect to "section:toggled" signal to react to state changes
function collapsible_section.onToggle(handler)
    return signals.connect("section:toggled", handler)
end

-- Factory function
function collapsible_section.create_section(title, parent_widget)
    local section = CollapsibleSection.new(title, nil, parent_widget)
    local result = section:create()

    if error_system.is_success(result) then
        result.section = section  -- Return the section object too
    end

    return result
end

return collapsible_section