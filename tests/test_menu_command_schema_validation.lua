#!/usr/bin/env luajit

-- Tests that all menu commands accept the params auto-injected by menu_system
-- (project_id, sequence_id) without schema validation errors.
--
-- This prevents "unknown param 'sequence_id'" errors at runtime.

require('test_env')

local command_schema = require("core.command_schema")

-- Parse menus.xml to extract all command names
local function parse_menu_commands(xml_path)
    local commands = {}
    local file = io.open(xml_path, "r")
    if not file then
        error("Cannot open " .. xml_path)
    end
    local xml_content = file:read("*a")
    file:close()

    -- Simple pattern matching for command="..." attributes
    for command_name in xml_content:gmatch('command="([^"]+)"') do
        -- Skip meta-commands handled specially by menu_system
        if command_name ~= "Undo" and command_name ~= "Redo" and command_name ~= "Quit" then
            commands[command_name] = true
        end
    end

    local result = {}
    for cmd in pairs(commands) do
        table.insert(result, cmd)
    end
    table.sort(result)
    return result
end

-- Load command spec by requiring the module
local function load_command_spec(command_name)
    -- Convert PascalCase to snake_case filename
    local filename = command_name:gsub("(%u)", function(c) return "_" .. c:lower() end):sub(2)
    local module_path = "core.commands." .. filename

    local ok, mod = pcall(require, module_path)
    if not ok then
        return nil, "module not found: " .. module_path
    end

    if type(mod) ~= "table" or type(mod.register) ~= "function" then
        return nil, "module has no register function"
    end

    -- Call register to get the spec (with dummy args)
    local dummy_executors = {}
    local dummy_undoers = {}
    local result = mod.register(dummy_executors, dummy_undoers, nil, function() end)

    if result and result.spec then
        return result.spec
    end

    return nil, "register did not return spec"
end

print("=== Menu Command Schema Validation Tests ===")

-- Find menus.xml
local menus_path = "../menus.xml"
local file = io.open(menus_path, "r")
if not file then
    menus_path = "menus.xml"  -- Try from project root
end
if file then file:close() end

local commands = parse_menu_commands(menus_path)
print(string.format("Found %d menu commands to validate", #commands))

local passed = 0
local failed = 0
local skipped = 0

for _, command_name in ipairs(commands) do
    local spec, err = load_command_spec(command_name)

    if not spec then
        print(string.format("  SKIP %s: %s", command_name, err or "no spec"))
        skipped = skipped + 1
    else
        -- Simulate params that menu_system auto-injects
        local test_params = {
            project_id = "test_project",
            sequence_id = "test_sequence",  -- This is the key one - auto-injected
        }

        -- Validate schema accepts these params (specifically checking for "unknown param" errors)
        local ok, _, validation_err = command_schema.validate_and_normalize(
            command_name,
            spec,
            test_params,
            { apply_defaults = false, asserts_enabled = false }
        )

        if ok then
            passed = passed + 1
        elseif validation_err and validation_err:match("unknown param") then
            -- This is what we're specifically testing for
            print(string.format("  FAIL %s: %s", command_name, validation_err))
            failed = failed + 1
        else
            -- Other validation errors (requires_any, etc.) are expected when
            -- we don't provide all required params - not our concern here
            passed = passed + 1
        end
    end
end

print(string.format("\nResults: %d passed, %d failed, %d skipped", passed, failed, skipped))

assert(failed == 0, string.format("Schema validation failed for %d commands", failed))

print("✅ test_menu_command_schema_validation.lua passed")
