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
-- Size: ~81 LOC
-- Volatility: unknown
--
-- @file selection_inspector.lua
-- Original intent (unreviewed):
-- scripts/core/runtime/controller/selection_inspector.lua
-- PURPOSE: Own selection policy (header text + batch), persist filter, and drive the inspector.
local error_system = require("src.lua.core.error_system")
local log = require("src.lua.core.logger").for_area("ui")

local M = { _view = nil, _adapter = nil }

local function header_for_count(n)
  if n <= 0 then return ""
  elseif n == 1 then return "1 item selected"
  else return string.format("%d items selected — batch edit enabled", n) end
end

local function is_batch(n) return (n or 0) > 1 end

function M.bind(view_module, adapter_module)
  error_system.assert_type(view_module, "table", "view_module", {
    operation = "bind_selection_inspector",
    component = "selection_inspector"
  })
  
  error_system.assert_type(adapter_module, "table", "adapter_module", {
    operation = "bind_selection_inspector", 
    component = "selection_inspector"
  })
  
  M._view, M._adapter = view_module, adapter_module
  
  -- Wire up the view's onFilterChanged callback to our handler
  if M._view.onFilterChanged ~= nil then
    log.warn("[inspector][controller] onFilterChanged already set, overriding")
  end
  
  M._view.onFilterChanged = function(query) 
    M.on_filter_changed(query) 
  end
  
  log.event("[inspector][controller] bound")
  
  return error_system.create_success({
    message = "Selection inspector bound successfully"
  })
end

-- Legacy init function for backward compatibility
function M.init(view_module, adapter_module)
  if not view_module or not adapter_module then
    return error_system.create_error({
      code = error_system.CODES.SELECTION_INSPECTOR_INIT_FAILED,
      category = "inspector",
      message = "Missing required modules for selection inspector initialization",
      operation = "init",
      component = "selection_inspector",
      user_message = "Cannot initialize selection inspector - required modules missing",
      technical_details = {
        view_module = view_module,
        adapter_module = adapter_module
      },
      remediation = {
        "Ensure view module is properly loaded",
        "Ensure adapter module is properly loaded",
        "Check module paths and require statements"
      }
    })
  end
  M._view, M._adapter = view_module, adapter_module
end

-- Call this whenever app selection changes (clips is a Lua array of bridged clip handles)
function M.on_selection_changed(clips)
  if not (M._view and M._adapter) then 
    log.warn("[inspector][controller] on_selection_changed called but not bound")
    return 
  end
  
  clips = clips or {}
  local count = #clips
  log.event("[inspector][controller] on_selection_changed %d clips", count)
  
  M._view.set_header_text(header_for_count(count))
  M._view.set_batch_enabled(is_batch(count))
  M._adapter.setSelectedClips(clips)  -- Use new function name
  
  local f = M._view.get_filter()
  if f and f ~= "" then 
    M._adapter.applySearchFilter(f)  -- Use new function name
  end
end

-- Call when the user edits the filter string (Lua is source of truth)
function M.on_filter_changed(text)
  if not (M._view and M._adapter) then 
    log.warn("[inspector][controller] on_filter_changed called but not bound")
    return 
  end
  
  log.event("[inspector][controller] on_filter_changed %s", text or '<nil>')
  
  -- Update view filter without triggering the callback (to prevent circular calls)
  M._view._filter = text or ""
  
  -- Update search input widget if it exists (placeholder for future widget_set_text)
  -- luacheck: ignore 542
  if M._view._search_input then
  end
  
  -- Apply the filter through the adapter
  M._adapter.applySearchFilter(text or "")
end

return M
