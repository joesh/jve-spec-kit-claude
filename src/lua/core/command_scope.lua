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
-- Size: ~46 LOC
-- Volatility: unknown
--
-- @file command_scope.lua
-- Original intent (unreviewed):
-- Command Scope Management
-- Provides simple panel/global scoping for UI-driven commands.
local focus_manager_ok, focus_manager = pcall(require, "ui.focus_manager")

local M = {}

local registry = {}

local function normalize_scope(opts)
    if not opts then
        return {scope = "global"}
    end
    local scope = opts.scope or "global"
    if scope ~= "global" and scope ~= "panel" then
        error("command_scope: unsupported scope '" .. tostring(scope) .. "'")
    end
    if scope == "panel" and (not opts.panel_id or opts.panel_id == "") then
        error("command_scope: panel scope requires panel_id")
    end
    return {
        scope = scope,
        panel_id = opts.panel_id
    }
end

-- Register scope metadata for a command type.
-- opts.scope: "global" (default) or "panel"
-- opts.panel_id: required when scope == "panel"
function M.register(command_type, opts)
    if type(command_type) ~= "string" or command_type == "" then
        error("command_scope.register: command_type must be non-empty string")
    end
    registry[command_type] = normalize_scope(opts)
end

function M.get(command_type)
    return registry[command_type]
end

function M.check(command)
    local entry = registry[command.type]
    if not entry or entry.scope == "global" then
        return true
    end

    if entry.scope == "panel" then
        if not focus_manager_ok or not focus_manager.get_focused_panel then
            return false, "Panel-scoped command requires focus_manager"
        end
        local focused = focus_manager.get_focused_panel()
        if focused ~= entry.panel_id then
            return false, string.format("Command '%s' requires focus on %s panel", command.type, entry.panel_id)
        end
        return true
    end

    return true
end

return M

