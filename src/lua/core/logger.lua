-- scripts/core/logger.lua
-- PURPOSE: Simple logging system for Lua scripts

local M = {}

function M.debug(component, message)
  print("[DEBUG][" .. (component or "unknown") .. "] " .. (message or ""))
end

function M.info(component, message)
  print("[INFO][" .. (component or "unknown") .. "] " .. (message or ""))
end

function M.warn(component, message)
  print("[WARN][" .. (component or "unknown") .. "] " .. (message or ""))
end

function M.error(component, message)
  print("[ERROR][" .. (component or "unknown") .. "] " .. (message or ""))
end

return M