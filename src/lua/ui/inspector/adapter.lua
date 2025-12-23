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
-- Size: ~134 LOC
-- Volatility: unknown
--
-- @file adapter.lua
-- Original intent (unreviewed):
-- scripts/ui/inspector/adapter.lua
-- PURPOSE: Single point that calls C++ panel methods. Keep policy out.
local error_system = require("core.error_system")
local logger = require("core.logger")
local ui_constants = require("core.ui_constants")

logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] loaded")

local A = {
  _panel = nil,
  _fn = { applySearchFilter = nil, setSelectedClips = nil },
  _selected_clips = {},
  _current_filter = "",
  _filtered_clips = {}
}

function A.bind(panel_handle, fns)
  if not panel_handle then
    return error_system.create_error({
      code = error_system.CODES.INVALID_PANEL_HANDLE,
      category = "inspector",
      message = "panel_handle is nil",
      operation = "bind_inspector_adapter",
      component = "inspector.adapter",
      user_message = "Cannot bind inspector adapter - invalid panel handle",
      remediation = {
        "Ensure the inspector panel was created successfully before binding",
        "Check that create_inspector_panel() returned a valid result"
      }
    })
  end
  
  error_system.assert_type(fns, "table", "fns", {
    operation = "bind_inspector_adapter", 
    component = "inspector.adapter"
  })
  
  if not (fns.applySearchFilter and fns.setSelectedClips) then
    return error_system.create_error({
      code = error_system.CODES.MISSING_REQUIRED_FUNCTIONS,
      category = "inspector", 
      message = "Missing required functions in fns table",
      operation = "bind_inspector_adapter",
      component = "inspector.adapter",
      technical_details = {
        has_applySearchFilter = not not fns.applySearchFilter,
        has_setSelectedClips = not not fns.setSelectedClips
      },
      remediation = {
        "Provide fns.applySearchFilter function",
        "Provide fns.setSelectedClips function"
      }
    })
  end
  
  A._panel, A._fn = panel_handle, fns
  return error_system.create_success({
    message = "Inspector adapter bound successfully"
  })
end

-- Lua-based filtering logic - filter clip metadata based on query
local function filterClipMetadata(clip, query)
  if not query or query == "" then
    return true  -- No filter, include all clips
  end
  
  local lower_query = string.lower(query)
  
  -- Filter by clip name/filename
  if clip.name and string.find(string.lower(clip.name), lower_query, 1, true) then
    return true
  end
  
  -- Filter by clip ID
  if clip.id and string.find(string.lower(clip.id), lower_query, 1, true) then
    return true
  end
  
  -- Filter by source file
  if clip.src and string.find(string.lower(clip.src), lower_query, 1, true) then
    return true
  end
  
  -- Filter by metadata fields if they exist
  if clip.metadata then
    for key, value in pairs(clip.metadata) do
      local key_str = tostring(key):lower()
      local value_str = tostring(value):lower()
      
      if string.find(key_str, lower_query, 1, true) or 
         string.find(value_str, lower_query, 1, true) then
        return true
      end
    end
  end
  
  return false
end

function A.applySearchFilter(query)
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] applySearchFilter " .. (query or '<nil>'))
  
  A._current_filter = query or ""
  
  -- Apply Lua-based filtering
  A._filtered_clips = {}
  for _, clip in ipairs(A._selected_clips) do
    if filterClipMetadata(clip, A._current_filter) then
      table.insert(A._filtered_clips, clip)
    end
  end
  
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, 
    "[inspector][adapter] Filtered " .. #A._selected_clips .. " clips to " .. #A._filtered_clips .. " matching '" .. A._current_filter .. "'")
  
  -- Update the inspector panel to show only filtered clips
  A._updateInspectorDisplay()
  
  -- Also call C++ function if available (for compatibility)
  if A._panel and A._fn.applySearchFilter then
    local success, result = pcall(A._fn.applySearchFilter, A._panel, query or "")
    if not success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] WARNING in C++ applySearchFilter: " .. tostring(result))
    end
  end
  
  return true
end

function A.setSelectedClips(clips)
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] setSelectedClips " .. #(clips or {}) .. " clips")
  
  A._selected_clips = clips or {}
  
  -- Reapply current filter to new clips
  A.applySearchFilter(A._current_filter)
  
  -- Also call C++ function if available (for compatibility)
  if A._panel and A._fn.setSelectedClips then
    local success, result = pcall(A._fn.setSelectedClips, A._panel, clips or {})
    if not success then
      logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] WARNING in C++ setSelectedClips: " .. tostring(result))
    end
  end
  
  return true
end

-- Update the inspector display with filtered clips
function A._updateInspectorDisplay()
  logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] Updating inspector display with " .. #A._filtered_clips .. " clips")
  
  -- This is where we would update the inspector UI to show only the filtered clips
  -- For now, we'll just log what would be displayed
  if #A._filtered_clips == 0 then
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] No clips match filter '" .. A._current_filter .. "'")
  else
    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter] Displaying " .. #A._filtered_clips .. " filtered clips:")
    for i, clip in ipairs(A._filtered_clips) do
      logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI, "[inspector][adapter]   " .. i .. ". " .. (clip.name or clip.id or "Unknown"))
    end
  end
end

-- Get currently filtered clips (for external access)
function A.getFilteredClips()
  return A._filtered_clips
end

-- Get current filter query (for external access)  
function A.getCurrentFilter()
  return A._current_filter
end

-- Legacy aliases for backward compatibility
function A.apply_filter(text)
  return A.applySearchFilter(text)
end

function A.set_selected_clips(list)
  return A.setSelectedClips(list)
end

return A
