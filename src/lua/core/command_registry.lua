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
-- Size: ~119 LOC
-- Volatility: unknown
--
-- @file command_registry.lua
-- Original intent (unreviewed):
-- CommandRegistry: Manages command executors and auto-loading
-- Extracted from command_manager.lua
local M = {}

local command_executors = {}
local command_specs     = {}
local command_undoers = {}
local db = nil
local error_handler = nil

-- Handle acronyms/numeric command names that don't convert cleanly to snake_case
local module_aliases = {
    -- FCP7 XML import (acronym doesn't convert to snake_case)
    ImportFCP7XML = "core.commands.import_fcp7_xml",

    -- Resolve import commands
    ImportResolveProject = "core.commands.import_resolve_project",
    ImportResolveDatabase = "core.commands.import_resolve_project",

    -- Project open
    OpenProject = "core.commands.open_project",

    -- Split lives in split_clip.lua (registers both Split and SplitClip)
    Split = "core.commands.split_clip",
    SplitClip = "core.commands.split_clip",
}
function M.init(database, set_last_error_fn)
    db = database
    error_handler = set_last_error_fn
    command_executors = {}
    command_undoers = {}
    command_specs     = {}
end

function M.register_executor(command_type, executor, undoer, spec)
    if type(command_type) ~= "string" or command_type == "" then
        error("register_executor requires a command type string")
    end
    if spec ~= nil and type(spec) ~= "table" then
        error("register_executor spec must be a table if provided")
    end
    if executor ~= nil and type(executor) ~= "function" then
        error("register_executor requires an executor function")
    end
    if executor then
        command_executors[command_type] = executor
    end
    if undoer ~= nil then
        if type(undoer) ~= "function" then
            error("register_executor undoer must be a function if provided")
        end
        command_undoers[command_type] = undoer
    end
    if (executor == nil) and (undoer == nil) then
        error("register_executor requires an executor, undoer, or both")
    end
    if spec ~= nil then
        command_specs[command_type] = spec
    end
end

function M.register_undoer(command_type, undoer)
    if type(command_type) ~= "string" or command_type == "" then
        error("register_undoer requires a command type string")
    end
    if type(undoer) ~= "function" then
        error("register_undoer requires an undoer function")
    end
    command_undoers[command_type] = undoer
end

function M.unregister_executor(command_type)
    if type(command_type) ~= "string" or command_type == "" then
        error("unregister_executor requires a command type string")
    end

    command_executors[command_type] = nil
    command_undoers[command_type] = nil
end

function M.get_executor(command_type)
    local executor = command_executors[command_type]
    
    if not executor then
        -- Attempt auto-load
        M.load_command_module(command_type)
        executor = command_executors[command_type]
    end
    
    return executor
end

function M.get_undoer(command_type)
    return command_undoers[command_type]
end

local function module_path_for(command_type)
    -- Undo executors live in the same module as their forward command.
    if command_type:sub(1, 4) == "Undo" then
        local base_type = command_type:sub(5)
        -- Reuse alias if base command has one
        if module_aliases[base_type] then
            return module_aliases[base_type]
        end
        command_type = base_type
    end

    if module_aliases[command_type] then
        return module_aliases[command_type]
    end
    local filename = command_type:gsub("%u", function(c) return "_" .. c:lower() end):sub(2)
    return "core.commands." .. filename
end

function M.load_command_module(command_type)
    -- If already loaded/registered with both executor and spec, short-circuit.
    -- Some legacy modules populate the executor table before returning the spec.
    -- In that case we must still load/register so strict schema validation doesn't fail with
    -- "No schema registered" even though an executor exists.
    if command_executors[command_type] and command_specs[command_type] then
        return true
    end

    local function try_load(path, register_type)
        local status, mod = pcall(require, path)
        if not status then
            return false, string.format("Failed to load command module '%s': %s", path, tostring(mod))
        end

        if type(mod) ~= "table" then
            return false, string.format("Command module '%s' did not return a table (got %s)", path, type(mod))
        end

        if not mod.register then
            return false, string.format("Command module '%s' missing register() function", path)
        end

        local registered = mod.register(command_executors, command_undoers, db, error_handler)
        if not registered then
            return false, string.format("Command module '%s' register() returned nil", path)
        end

        -- Two supported module return styles:
        --   A) Single registration: { executor=fn, undoer=fn|nil, spec=table|nil }
        --   B) Multi registration: { ["CmdName"]={executor=..., undoer=..., spec=...}, ... }
        --
        -- Style (B) is needed when a single file registers multiple commands with different specs.
        if registered.executor ~= nil then
            if not register_type then
                return false, string.format("Command module '%s' missing register_type for single registration", path)
            end
            if type(registered.executor) ~= "function" then
                return false, string.format("Command module '%s' register() executor must be a function", path)
            end
            M.register_executor(register_type, registered.executor, registered.undoer, registered.spec)
            return true
        end

        local any = false
        for cmd_name, entry in pairs(registered) do
            if type(cmd_name) == "string" and type(entry) == "table" then
                if entry.executor ~= nil or entry.undoer ~= nil then
                    any = true
                    M.register_executor(cmd_name, entry.executor, entry.undoer, entry.spec)
                end
            end
        end
        if not any then
            return false, string.format("Command module '%s' register() returned a table with no registrations", path)
        end
        return true
    end

    local is_undo_type = command_type:sub(1, 4) == "Undo"
    local base_type = is_undo_type and command_type:sub(5) or nil
    local primary_path = module_path_for(command_type)
    local register_type = is_undo_type and base_type or command_type
    local loaded, err = try_load(primary_path, register_type)
    if not loaded then
        print(string.format("ERROR: %s", err or ("Unable to load " .. primary_path)))
        return false
    end

    -- For Undo* commands, also register the undoer under the base command type so
    -- command_manager.execute_undo can find it without invoking the executor path.
    if is_undo_type and base_type then
        local undoer = command_undoers[command_type] or command_undoers[base_type]
        if undoer then
            command_undoers[base_type] = undoer
        end
    end

    return true
end


function M.get_spec(command_type)
    local spec = command_specs[command_type]
    if spec == nil then
        M.load_command_module(command_type)
        spec = command_specs[command_type]
    end
    return spec
end

return M