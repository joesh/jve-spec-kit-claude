-- CommandRegistry: Manages command executors and auto-loading
-- Extracted from command_manager.lua

local M = {}

local command_executors = {}
local command_undoers = {}
local db = nil
local error_handler = nil

-- Handle acronyms/numeric command names that don't convert cleanly to snake_case
local module_aliases = {
    ImportFCP7XML = "core.commands.import_fcp7_xml",
}
function M.init(database, set_last_error_fn)
    db = database
    error_handler = set_last_error_fn
    command_executors = {}
    command_undoers = {}
end

function M.register_executor(command_type, executor, undoer)
    if type(command_type) ~= "string" or command_type == "" then
        error("register_executor requires a command type string")
    end
    if type(executor) ~= "function" then
        error("register_executor requires an executor function")
    end

    command_executors[command_type] = executor

    if undoer ~= nil then
        if type(undoer) ~= "function" then
            error("register_executor undoer must be a function if provided")
        end
        command_undoers[command_type] = undoer
    end
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

function M.load_command_module(command_type)
    -- Convert CamelCase to snake_case for file path, with alias overrides
    local module_path = module_aliases[command_type]
    if not module_path then
        local filename = command_type:gsub("%u", function(c) return "_" .. c:lower() end):sub(2)
        module_path = "core.commands." .. filename
    end

    local status, mod = pcall(require, module_path)
    if not status then
        print(string.format("ERROR: Failed to load command module '%s': %s",
                            module_path, tostring(mod)))
        return false
    end

    if type(mod) ~= "table" then
        print(string.format("ERROR: Command module '%s' did not return a table (got %s)",
                            module_path, type(mod)))
        return false
    end

    if not mod.register then
        print(string.format("ERROR: Command module '%s' missing register() function", module_path))
        return false
    end

    local registered = mod.register(command_executors, command_undoers, db, error_handler)
    if not registered then
        print(string.format("ERROR: Command module '%s' register() returned nil", module_path))
        return false
    end

    if not registered.executor then
        print(string.format("ERROR: Command module '%s' register() missing executor function", module_path))
        return false
    end

    M.register_executor(command_type, registered.executor, registered.undoer)
    return true
end

return M
