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
-- Size: ~246 LOC
-- Volatility: unknown
--
-- @file main_window.lua
-- Original intent (unreviewed):
-- scripts/ui/main_window.lua
-- PURPOSE: Pure Lua main window creation for professional video editor
-- Creates DaVinci Resolve-style layout with project browser, timeline, and inspector
local error_system = require("scripts.core.error_system")
local logger = require("scripts.core.logger")
local ui_constants = require("scripts.core.ui_constants")
local qt_constants = require("scripts.core.qt_constants")

-- Import the existing inspector modules
local inspector_view = require("scripts.ui.inspector.view")
local inspector_adapter = require("scripts.ui.inspector.adapter")
local selection_inspector = require("scripts.core.runtime.controller.selection_inspector")

local M = {
  main_window = nil,
  timeline_widget = nil,
  project_browser = nil,
  inspector_panel = nil,
  preview_area = nil
}

function M.create_main_window()
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] Creating professional video editor layout")
  
  -- Create main window
  local main_success, main_window = pcall(qt_constants.WIDGET.CREATE_MAIN_WINDOW)
  if not main_success or not main_window then
    return error_system.create_error({
      message = "Failed to create main window",
      operation = "create_main_window",
      component = "main_window"
    })
  end
  
  M.main_window = main_window
  
  -- Set window properties
  pcall(qt_constants.PROPERTIES.SET_TITLE, main_window, "JVE Editor - Professional Video Editor")
  pcall(qt_constants.PROPERTIES.SET_SIZE, main_window, 1600, 900)
  
  -- Create the layout
  local layout_result = M.create_professional_layout()
  if error_system.is_error(layout_result) then
    return layout_result
  end
  
  -- Initialize the inspector system
  local inspector_result = M.setup_inspector()
  if error_system.is_error(inspector_result) then
    return inspector_result
  end
  
  -- Show the window
  pcall(qt_constants.DISPLAY.SHOW, main_window)
  
  logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] ✅ Professional video editor created successfully")
  
  return error_system.create_success({
    message = "Main window created successfully",
    return_values = {
      main_window = main_window,
      timeline = M.timeline_widget,
      inspector = M.inspector_panel,
      project_browser = M.project_browser
    }
  })
end

function M.create_professional_layout()
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] Creating professional layout")
  
  -- Create main splitter (horizontal: project browser | center area | inspector)
  local splitter_success, main_splitter = pcall(qt_constants.LAYOUT.CREATE_SPLITTER, "horizontal")
  if not splitter_success then
    return error_system.create_error({
      message = "Failed to create main splitter",
      operation = "create_professional_layout",
      component = "main_window"
    })
  end
  
  -- Create project browser (left panel)
  local browser_result = M.create_project_browser()
  if error_system.is_error(browser_result) then
    return browser_result
  end
  
  -- Create center area (preview + timeline)
  local center_result = M.create_center_area()
  if error_system.is_error(center_result) then
    return center_result
  end
  
  -- Create inspector panel (right panel)  
  local inspector_result = M.create_inspector_panel()
  if error_system.is_error(inspector_result) then
    return inspector_result
  end
  
  -- Add panels to splitter
  pcall(qt_constants.LAYOUT.ADD_WIDGET, main_splitter, M.project_browser)
  pcall(qt_constants.LAYOUT.ADD_WIDGET, main_splitter, M.preview_area)
  pcall(qt_constants.LAYOUT.ADD_WIDGET, main_splitter, M.inspector_panel)
  
  -- Set splitter proportions (project browser: 25%, center: 50%, inspector: 25%)
  pcall(qt_constants.LAYOUT.SET_SPLITTER_SIZES, main_splitter, {400, 800, 400})
  
  -- Set as central widget
  pcall(qt_constants.LAYOUT.SET_CENTRAL_WIDGET, M.main_window, main_splitter)
  
  return error_system.create_success({
    message = "Professional layout created successfully"
  })
end

function M.create_project_browser()
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] Creating project browser")
  
  -- Create project browser widget
  local browser_success, browser_widget = pcall(qt_constants.WIDGET.CREATE)
  if not browser_success then
    return error_system.create_error({
      message = "Failed to create project browser widget",
      operation = "create_project_browser",
      component = "main_window"
    })
  end
  
  M.project_browser = browser_widget
  
  -- Create vertical layout for browser
  local layout_success, browser_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if not layout_success then
    return error_system.create_error({
      message = "Failed to create project browser layout",
      operation = "create_project_browser", 
      component = "main_window"
    })
  end
  
  -- Add title
  local title_success, title_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "Project Browser")
  if title_success then
    pcall(qt_constants.PROPERTIES.SET_STYLE, title_label, "font-weight: bold; padding: 8px; background: #2a2a2a; color: white;")
    pcall(qt_constants.LAYOUT.ADD_WIDGET, browser_layout, title_label)
  end
  
  -- Add tree widget for bins and media
  local tree_success, tree_widget = pcall(qt_constants.WIDGET.CREATE_TREE)
  if tree_success then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, browser_layout, tree_widget)
  end
  
  pcall(qt_constants.LAYOUT.SET_ON_WIDGET, browser_widget, browser_layout)
  
  return error_system.create_success({
    message = "Project browser created successfully"
  })
end

function M.create_center_area()
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] Creating center area")
  
  -- Create center widget with vertical splitter (preview area + timeline)
  local center_success, center_widget = pcall(qt_constants.WIDGET.CREATE)
  if not center_success then
    return error_system.create_error({
      message = "Failed to create center widget",
      operation = "create_center_area",
      component = "main_window"
    })
  end
  
  M.preview_area = center_widget
  
  -- Create vertical splitter
  local splitter_success, center_splitter = pcall(qt_constants.LAYOUT.CREATE_SPLITTER, "vertical")
  if not splitter_success then
    return error_system.create_error({
      message = "Failed to create center splitter",
      operation = "create_center_area",
      component = "main_window"
    })
  end
  
  -- Create preview area (top)
  local preview_success, preview_widget = pcall(qt_constants.WIDGET.CREATE)
  if preview_success then
    local preview_layout_success, preview_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
    if preview_layout_success then
      local preview_label_success, preview_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "Viewer Panel\n(To be implemented)")
      if preview_label_success then
        pcall(qt_constants.PROPERTIES.SET_STYLE, preview_label, "font-size: 14px; color: #888; text-align: center; padding: 40px;")
        pcall(qt_constants.LAYOUT.ADD_WIDGET, preview_layout, preview_label)
      end
      pcall(qt_constants.LAYOUT.SET_ON_WIDGET, preview_widget, preview_layout)
    end
    pcall(qt_constants.LAYOUT.ADD_WIDGET, center_splitter, preview_widget)
  end
  
  -- Create timeline area (bottom) - this will integrate with the ScriptableTimeline
  local timeline_success, timeline_widget = pcall(qt_constants.WIDGET.CREATE_TIMELINE)
  if timeline_success then
    M.timeline_widget = timeline_widget
    pcall(qt_constants.LAYOUT.ADD_WIDGET, center_splitter, timeline_widget)
  else
    -- Fallback: create placeholder
    local timeline_placeholder_success, timeline_placeholder = pcall(qt_constants.WIDGET.CREATE)
    if timeline_placeholder_success then
      local timeline_layout_success, timeline_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
      if timeline_layout_success then
        local timeline_label_success, timeline_label = pcall(qt_constants.WIDGET.CREATE_LABEL, "Timeline\n(ScriptableTimeline Integration)")
        if timeline_label_success then
          pcall(qt_constants.PROPERTIES.SET_STYLE, timeline_label, "font-size: 14px; color: #888; text-align: center; padding: 20px;")
          pcall(qt_constants.LAYOUT.ADD_WIDGET, timeline_layout, timeline_label)
        end
        pcall(qt_constants.LAYOUT.SET_ON_WIDGET, timeline_placeholder, timeline_layout)
      end
      pcall(qt_constants.LAYOUT.ADD_WIDGET, center_splitter, timeline_placeholder)
      M.timeline_widget = timeline_placeholder
    end
  end
  
  -- Set splitter proportions (preview: 60%, timeline: 40%)
  pcall(qt_constants.LAYOUT.SET_SPLITTER_SIZES, center_splitter, {360, 240})
  
  -- Set splitter as center widget layout
  local center_layout_success, center_layout = pcall(qt_constants.LAYOUT.CREATE_VBOX)
  if center_layout_success then
    pcall(qt_constants.LAYOUT.ADD_WIDGET, center_layout, center_splitter)
    pcall(qt_constants.LAYOUT.SET_ON_WIDGET, center_widget, center_layout)
  end
  
  return error_system.create_success({
    message = "Center area created successfully"
  })
end

function M.create_inspector_panel()
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] Creating inspector panel")
  
  -- Create inspector widget that will be managed by the Lua inspector system
  local inspector_success, inspector_widget = pcall(qt_constants.WIDGET.CREATE)
  if not inspector_success then
    return error_system.create_error({
      message = "Failed to create inspector widget",
      operation = "create_inspector_panel",
      component = "main_window"
    })
  end
  
  M.inspector_panel = inspector_widget
  
  -- The inspector widget will be populated by the existing Lua inspector modules
  -- in the setup_inspector() function
  
  return error_system.create_success({
    message = "Inspector panel widget created successfully"
  })
end

function M.setup_inspector()
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] Setting up inspector system")
  
  if not M.inspector_panel then
    return error_system.create_error({
      message = "Inspector panel not created",
      operation = "setup_inspector",
      component = "main_window"
    })
  end
  
  -- Initialize the inspector view with our widget
  local view_result = inspector_view.init(M.inspector_panel)
  if error_system.is_error(view_result) then
    return view_result
  end
  
  -- Mount the inspector view
  local mount_result = inspector_view.mount(M.inspector_panel)
  if error_system.is_error(mount_result) then
    return mount_result
  end
  
  -- Set up the adapter with dummy functions for now
  local adapter_functions = {
    applySearchFilter = function(panel, query)
      logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] applySearchFilter called with: " .. (query or ""))
      return true
    end,
    setSelectedClips = function(panel, clips)
      logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] setSelectedClips called with " .. #(clips or {}) .. " clips")
      return true
    end
  }
  
  local adapter_result = inspector_adapter.bind(M.inspector_panel, adapter_functions)
  if error_system.is_error(adapter_result) then
    return adapter_result
  end
  
  -- Bind the controller
  local controller_result = selection_inspector.bind(inspector_view, inspector_adapter)
  if error_system.is_error(controller_result) then
    return controller_result
  end
  
  -- Create the search row UI
  local search_result = inspector_view.ensure_search_row()
  if error_system.is_error(search_result) then
    logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] Warning: Failed to create search row: " .. error_system.format_debug_error(search_result))
  else
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[main_window] ✅ Inspector search row created successfully")
  end
  
  return error_system.create_success({
    message = "Inspector system setup completed"
  })
end

-- Get references to created widgets for external access
function M.get_main_window()
  return M.main_window
end

function M.get_timeline_widget()
  return M.timeline_widget
end

function M.get_inspector_panel()
  return M.inspector_panel
end

function M.get_project_browser()
  return M.project_browser
end

return M