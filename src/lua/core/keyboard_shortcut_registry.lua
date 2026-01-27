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
-- Size: ~238 LOC
-- Volatility: unknown
--
-- @file keyboard_shortcut_registry.lua
-- Original intent (unreviewed):
-- Keyboard Shortcut Registry
-- Central registry of all available commands and their assigned shortcuts
-- Supports customization, conflict detection, and preset management
local M = {}

-- Command registry: all commands that can have shortcuts
-- Format: {id, category, name, description, default_shortcuts, handler}
M.commands = {}

-- Active shortcuts mapping: {key_combo} -> command_id
M.active_shortcuts = {}

-- Preset storage
M.current_preset = "Default"
M.presets = {}

-- Register a command that can be assigned a keyboard shortcut
function M.register_command(command_def)
    --[[
    command_def = {
        id = "timeline.undo",
        category = "Edit",
        name = "Undo",
        description = "Undo the last operation",
        default_shortcuts = {"Cmd+Z", "Ctrl+Z"},  -- Platform-agnostic
        context = "timeline",  -- Optional: only active in certain contexts
        handler = function() ... end
    }
    ]]--

    assert(type(command_def) == "table", "command_def must be a table")
    assert(type(command_def.id) == "string" and command_def.id ~= "", "Command must have an id")
    assert(M.commands[command_def.id] == nil, "Command already registered: " .. command_def.id)
    assert(type(command_def.category) == "string" and command_def.category ~= "", "Command " .. command_def.id .. " missing category")
    assert(command_def.description ~= nil, "Command " .. command_def.id .. " missing description")
    assert(type(command_def.name) == "string" and command_def.name ~= "", "Command " .. command_def.id .. " missing name")
    assert(type(command_def.default_shortcuts) == "table", "Command " .. command_def.id .. " must provide default_shortcuts table")

    local default_shortcuts = {}
    for index, shortcut in ipairs(command_def.default_shortcuts) do
        assert(type(shortcut) == "string" and shortcut ~= "", string.format("Command %s has invalid default shortcut at index %d", command_def.id, index))
        table.insert(default_shortcuts, shortcut)
    end

    M.commands[command_def.id] = {
        id = command_def.id,
        category = command_def.category,
        name = command_def.name,
        description = command_def.description,
        default_shortcuts = default_shortcuts,
        context = command_def.context,
        handler = command_def.handler,
        current_shortcuts = {}
    }
end

-- Convert platform-agnostic shortcut notation to Qt key codes
-- "Cmd+Z" -> {key=90, modifiers=Meta} on macOS, {key=90, modifiers=Control} on Windows
function M.parse_shortcut(shortcut_string)
    local parts = {}
    for part in shortcut_string:gmatch("[^+]+") do
        table.insert(parts, part)
    end

    local modifiers = 0
    local key_name = parts[#parts]  -- Last part is the key

    local KEY = require('core.keyboard_shortcuts').KEY
    local MOD = require('core.keyboard_shortcuts').MOD

    -- Parse modifiers
    for i = 1, #parts - 1 do
        local mod = parts[i]:lower()
        if mod == "cmd" or mod == "command" then
            -- On macOS use Meta, on others use Control
            if jit.os == "OSX" then
                modifiers = modifiers + MOD.Meta
            else
                modifiers = modifiers + MOD.Control
            end
        elseif mod == "ctrl" or mod == "control" then
            modifiers = modifiers + MOD.Control
        elseif mod == "alt" or mod == "option" then
            modifiers = modifiers + MOD.Alt
        elseif mod == "shift" then
            modifiers = modifiers + MOD.Shift
        end
    end

    -- Parse key
    local key_code = KEY[key_name]
    if not key_code then
        -- Try single character
        if #key_name == 1 then
            key_code = string.byte(key_name:upper())
        end
    end

    if not key_code then
        return nil, string.format("Unknown key: %s", key_name)
    end

    return {
        key = key_code,
        modifiers = modifiers,
        string = shortcut_string
    }
end

-- Format a key combo as human-readable string
function M.format_shortcut(key, modifiers)
    local parts = {}
    local MOD = require('core.keyboard_shortcuts').MOD
    local bit = require("bit")

    -- Platform-specific ordering
    if jit.os == "OSX" then
        -- Mac order: Cmd, Shift, Alt, Ctrl
        if bit.band(modifiers, MOD.Meta) ~= 0 then table.insert(parts, "Cmd") end
        if bit.band(modifiers, MOD.Shift) ~= 0 then table.insert(parts, "Shift") end
        if bit.band(modifiers, MOD.Alt) ~= 0 then table.insert(parts, "Option") end
        if bit.band(modifiers, MOD.Control) ~= 0 then table.insert(parts, "Ctrl") end
    else
        -- Windows/Linux order: Ctrl, Alt, Shift
        if bit.band(modifiers, MOD.Control) ~= 0 then table.insert(parts, "Ctrl") end
        if bit.band(modifiers, MOD.Alt) ~= 0 then table.insert(parts, "Alt") end
        if bit.band(modifiers, MOD.Shift) ~= 0 then table.insert(parts, "Shift") end
    end

    -- Add key name
    local KEY = require('core.keyboard_shortcuts').KEY
    local key_name = nil

    -- Reverse lookup in KEY table
    for name, code in pairs(KEY) do
        if code == key then
            key_name = name
            break
        end
    end

    if not key_name then
        -- Try character
        if key >= 32 and key < 127 then
            key_name = string.char(key)
        else
            key_name = string.format("Key%d", key)
        end
    end

    table.insert(parts, key_name)
    return table.concat(parts, "+")
end

-- Assign a shortcut to a command
-- Returns: success, error_message
function M.assign_shortcut(command_id, shortcut_string)
    local command = M.commands[command_id]
    if not command then
        return false, string.format("Unknown command: %s", command_id)
    end

    local shortcut, err = M.parse_shortcut(shortcut_string)
    if not shortcut then
        return false, err
    end

    -- Check for conflicts
    local conflict = M.find_conflict(shortcut.key, shortcut.modifiers)
    if conflict and conflict ~= command_id then
        return false, string.format("Shortcut already assigned to: %s", M.commands[conflict].name)
    end

    -- Remove from old mapping
    if conflict then
        local old_command = M.commands[conflict]
        for i, sc in ipairs(old_command.current_shortcuts) do
            if sc.key == shortcut.key and sc.modifiers == shortcut.modifiers then
                table.remove(old_command.current_shortcuts, i)
                break
            end
        end
    end

    -- Add to command's shortcuts
    table.insert(command.current_shortcuts, shortcut)

    -- Add to active mapping
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    M.active_shortcuts[combo_key] = command_id

    return true
end

-- Find which command (if any) uses a given key combination
function M.find_conflict(key, modifiers)
    local combo_key = string.format("%d_%d", key, modifiers)
    return M.active_shortcuts[combo_key]
end

-- Remove a shortcut from a command
function M.remove_shortcut(command_id, shortcut_string)
    local command = M.commands[command_id]
    if not command then
        return false
    end

    local shortcut = M.parse_shortcut(shortcut_string)
    if not shortcut then
        return false
    end

    -- Remove from command
    for i, sc in ipairs(command.current_shortcuts) do
        if sc.key == shortcut.key and sc.modifiers == shortcut.modifiers then
            table.remove(command.current_shortcuts, i)
            break
        end
    end

    -- Remove from active mapping
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    M.active_shortcuts[combo_key] = nil

    return true
end

-- Get all commands organized by category
function M.get_commands_by_category()
    local by_category = {}

    for _, command in pairs(M.commands) do
        local cat = command.category
        if not by_category[cat] then
            by_category[cat] = {}
        end
        table.insert(by_category[cat], command)
    end

    -- Sort each category
    for _, commands in pairs(by_category) do
        table.sort(commands, function(a, b)
            return a.name < b.name
        end)
    end

    return by_category
end

-- Save current shortcuts as a preset
function M.save_preset(preset_name)
    local preset = {}

    for command_id, command in pairs(M.commands) do
        if #command.current_shortcuts > 0 then
            preset[command_id] = {}
            for _, shortcut in ipairs(command.current_shortcuts) do
                table.insert(preset[command_id], shortcut.string)
            end
        end
    end

    M.presets[preset_name] = preset
    M.current_preset = preset_name

    -- TODO: Persist to database
    return true
end

-- Load a preset
function M.load_preset(preset_name)
    local preset = M.presets[preset_name]
    if not preset then
        return false, string.format("Preset not found: %s", preset_name)
    end

    -- Clear all current shortcuts
    for _, command in pairs(M.commands) do
        command.current_shortcuts = {}
    end
    M.active_shortcuts = {}

    -- Apply preset
    for command_id, shortcuts in pairs(preset) do
        for _, shortcut_string in ipairs(shortcuts) do
            M.assign_shortcut(command_id, shortcut_string)
        end
    end

    M.current_preset = preset_name
    return true
end

-- Reset to default shortcuts
function M.reset_to_defaults()
    for _, command in pairs(M.commands) do
        command.current_shortcuts = {}
    end
    M.active_shortcuts = {}

    for command_id, command in pairs(M.commands) do
        for _, shortcut_string in ipairs(command.default_shortcuts) do
            M.assign_shortcut(command_id, shortcut_string)
        end
    end

    M.current_preset = "Default"
    return true
end

-- Handle a key event and execute matching command
function M.handle_key_event(key, modifiers, context)
    local combo_key = string.format("%d_%d", key, modifiers)
    local command_id = M.active_shortcuts[combo_key]

    if not command_id then
        return false  -- No handler for this key combo
    end

    local command = M.commands[command_id]

    -- Check context match (supports single context or array of contexts)
    if command.context then
        local contexts = type(command.context) == "table" and command.context or {command.context}
        local matched = false
        for _, ctx in ipairs(contexts) do
            if ctx == context then matched = true; break end
        end
        if not matched then return false end
    end

    -- Execute handler
    if command.handler then
        command.handler()
        return true
    end

    return false
end

return M
