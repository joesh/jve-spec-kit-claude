--- Keyboard shortcut registry: TOML is the sole authority for keybindings
--
-- Responsibilities:
-- - Parse TOML keybinding files (keymaps/*.jvekeys)
-- - Store key combo → command mappings (single registry: M.keybindings)
-- - Dispatch key events to command_manager.execute_interactive()
-- - Command metadata for shortcut editor UI (register_command)
-- - Conflict detection, preset management
--
-- @file keyboard_shortcut_registry.lua
local M = {}
local kb_constants = require("core.keyboard_constants")
local log = require("core.logger").for_area("ui")

-- Command registry: all commands that can have shortcuts (for shortcut editor UI)
-- Format: {id, category, name, description, current_shortcuts}
M.commands = {}

-- TOML-based keybindings: {combo_key} -> array of {command_name, positional_args, named_params, contexts, category, shortcut}
-- Multiple bindings per combo key supported — handle_key_event picks first context match.
-- Single source of truth for all keybindings. Populated by load_keybindings().
M.keybindings = {}

-- Path to the loaded TOML file (for reset_to_defaults)
M.loaded_toml_path = nil

-- Reference to command_manager (set via set_command_manager)
local command_manager = nil

-- Preset storage
M.current_preset = "Default"
M.presets = {}

function M.set_command_manager(cmd_mgr)
    command_manager = cmd_mgr
end

-- Register a command that can be assigned a keyboard shortcut (metadata for UI)
function M.register_command(command_def)
    assert(type(command_def) == "table", "command_def must be a table")
    assert(type(command_def.id) == "string" and command_def.id ~= "", "Command must have an id")
    assert(M.commands[command_def.id] == nil, "Command already registered: " .. command_def.id)
    assert(type(command_def.category) == "string" and command_def.category ~= "", "Command " .. command_def.id .. " missing category")
    assert(command_def.description ~= nil, "Command " .. command_def.id .. " missing description")
    assert(type(command_def.name) == "string" and command_def.name ~= "", "Command " .. command_def.id .. " missing name")

    M.commands[command_def.id] = {
        id = command_def.id,
        category = command_def.category,
        name = command_def.name,
        description = command_def.description,
        context = command_def.context,
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

    local KEY = kb_constants.KEY
    local MOD = kb_constants.MOD

    -- Parse modifiers
    -- Qt swaps Control/Meta on macOS:
    --   Command key (⌘) → Qt::ControlModifier (0x04000000)
    --   Control key (^) → Qt::MetaModifier (0x10000000)
    for i = 1, #parts - 1 do
        local mod = parts[i]:lower()
        if mod == "cmd" or mod == "command" then
            -- Command key: ControlModifier on all platforms
            -- (on macOS Qt maps Command to ControlModifier)
            modifiers = modifiers + MOD.Control
        elseif mod == "ctrl" or mod == "control" then
            -- Physical Control key: MetaModifier on macOS, ControlModifier elsewhere
            if jit.os == "OSX" then
                modifiers = modifiers + MOD.Meta
            else
                modifiers = modifiers + MOD.Control
            end
        elseif mod == "alt" or mod == "option" then
            modifiers = modifiers + MOD.Alt
        elseif mod == "shift" then
            modifiers = modifiers + MOD.Shift
        else
            assert(false, string.format(
                "parse_shortcut: unknown modifier '%s' in '%s'",
                parts[i], shortcut_string))
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

    -- Normalize shifted symbols: "Shift+Grave" → Tilde (no Shift),
    -- "Shift+Tilde" → Tilde (no Shift). Canonical = shifted key, no Shift.
    local bit = require("bit")
    if bit.band(modifiers, MOD.Shift) ~= 0 then
        local promoted = kb_constants.UNSHIFTED_TO_SHIFTED[key_code]
        if promoted then
            key_code = promoted
            modifiers = bit.band(modifiers, bit.bnot(MOD.Shift))
        elseif kb_constants.SHIFTED_SYMBOL_KEYS[key_code] then
            modifiers = bit.band(modifiers, bit.bnot(MOD.Shift))
        end
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
    local MOD = kb_constants.MOD
    local bit = require("bit")

    -- Platform-specific ordering
    -- Qt swaps Control/Meta on macOS:
    --   ControlModifier = Command key (⌘), MetaModifier = Control key (^)
    if jit.os == "OSX" then
        -- Mac order: Cmd, Shift, Option, Ctrl
        if bit.band(modifiers, MOD.Control) ~= 0 then table.insert(parts, "Cmd") end
        if bit.band(modifiers, MOD.Shift) ~= 0 then table.insert(parts, "Shift") end
        if bit.band(modifiers, MOD.Alt) ~= 0 then table.insert(parts, "Option") end
        if bit.band(modifiers, MOD.Meta) ~= 0 then table.insert(parts, "Ctrl") end
    else
        -- Windows/Linux order: Ctrl, Alt, Shift
        if bit.band(modifiers, MOD.Control) ~= 0 then table.insert(parts, "Ctrl") end
        if bit.band(modifiers, MOD.Alt) ~= 0 then table.insert(parts, "Alt") end
        if bit.band(modifiers, MOD.Shift) ~= 0 then table.insert(parts, "Shift") end
    end

    -- Add key name
    local KEY = kb_constants.KEY
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

-- Assign a shortcut to a command (writes to keybindings)
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

    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)

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

    -- Add to command's shortcuts (for UI display)
    table.insert(command.current_shortcuts, shortcut)

    -- Write to keybindings (the single registry)
    if not M.keybindings[combo_key] then
        M.keybindings[combo_key] = {}
    end
    M.keybindings[combo_key][#M.keybindings[combo_key] + 1] = {
        command_name = command_id,
        named_params = {},
        positional_args = {},
        contexts = {},
        category = command.category or "",
        shortcut = shortcut,
    }

    return true
end

-- Find which command (if any) uses a given key combination.
-- Returns first global (no-context) binding's command name, or first binding if all contextual.
function M.find_conflict(key, modifiers)
    local combo_key = string.format("%d_%d", key, modifiers)
    local bindings = M.keybindings[combo_key]
    if not bindings or #bindings == 0 then
        return nil
    end
    -- Prefer global binding for conflict detection
    for _, b in ipairs(bindings) do
        if not b.contexts or #b.contexts == 0 then
            return b.command_name
        end
    end
    return bindings[1].command_name
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

    -- Remove from keybindings
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    local bindings = M.keybindings[combo_key]
    if bindings then
        for i = #bindings, 1, -1 do
            if bindings[i].command_name == command_id then
                table.remove(bindings, i)
            end
        end
        if #bindings == 0 then
            M.keybindings[combo_key] = nil
        end
    end

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
    M.keybindings = {}

    -- Apply preset
    for command_id, shortcuts in pairs(preset) do
        for _, shortcut_string in ipairs(shortcuts) do
            M.assign_shortcut(command_id, shortcut_string)
        end
    end

    M.current_preset = preset_name
    return true
end

-- Reset to defaults: re-load TOML file
function M.reset_to_defaults()
    assert(M.loaded_toml_path, "reset_to_defaults: no TOML file loaded yet")

    for _, command in pairs(M.commands) do
        command.current_shortcuts = {}
    end
    M.keybindings = {}

    M.load_keybindings(M.loaded_toml_path)
    M.current_preset = "Default"
    return true
end

--- Parse a binding value string: "CommandName [positional...] [key=value...] [@context...]"
-- Returns: {command_name, positional_args, named_params, contexts}
function M.parse_binding_value(value_str)
    assert(type(value_str) == "string" and value_str ~= "",
        "parse_binding_value: value_str must be non-empty string")

    local tokens = {}
    for token in value_str:gmatch("%S+") do
        tokens[#tokens + 1] = token
    end
    assert(#tokens >= 1, "parse_binding_value: empty binding value: " .. value_str)

    local command_name = tokens[1]
    local positional_args = {}
    local named_params = {}
    local contexts = {}

    for i = 2, #tokens do
        local token = tokens[i]
        if token:sub(1, 1) == "@" then
            -- Context suffix
            contexts[#contexts + 1] = token:sub(2)
        elseif token:find("=") then
            -- Named param: key=value
            local k, v = token:match("^([^=]+)=(.+)$")
            assert(k and v, "parse_binding_value: malformed named param: " .. token)
            -- Auto-convert booleans and numbers
            if v == "true" then v = true
            elseif v == "false" then v = false
            elseif tonumber(v) then v = tonumber(v)
            end
            named_params[k] = v
        else
            -- Positional arg
            positional_args[#positional_args + 1] = token
        end
    end

    return {
        command_name = command_name,
        positional_args = positional_args,
        named_params = named_params,
        contexts = contexts,
    }
end

--- Load keybindings from a TOML file (keymaps/*.jvekeys).
-- Populates M.keybindings with parsed command/params/contexts per key combo.
function M.load_keybindings(file_path)
    assert(type(file_path) == "string", "load_keybindings: file_path must be string")

    local f = io.open(file_path, "r")
    assert(f, "load_keybindings: cannot open " .. file_path)
    local content = f:read("*a")
    f:close()

    local tinytoml = require("tinytoml")
    local data, err = tinytoml.parse(content, {load_from_string = true})
    assert(data, "load_keybindings: TOML parse error: " .. tostring(err))

    -- Store path for reset_to_defaults
    M.loaded_toml_path = file_path

    local count = 0
    for category, entries in pairs(data) do
        assert(type(entries) == "table",
            "load_keybindings: section [" .. category .. "] must be a table")
        for key_combo_str, value_str in pairs(entries) do
            local binding = M.parse_binding_value(value_str)
            assert(binding, string.format(
                "load_keybindings: bad binding value '%s' for key '%s' in [%s]",
                tostring(value_str), key_combo_str, category))
            binding.category = category

            -- Parse key combo to get combo_key for lookup
            local shortcut, parse_err = M.parse_shortcut(key_combo_str)
            assert(shortcut, string.format(
                "load_keybindings: bad key combo '%s' in [%s]: %s",
                key_combo_str, category, tostring(parse_err)))

            local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
            binding.shortcut = shortcut
            if not M.keybindings[combo_key] then
                M.keybindings[combo_key] = {}
            end
            M.keybindings[combo_key][#M.keybindings[combo_key] + 1] = binding
            log.detail("  loaded: '%s' → combo_key=%s → %s", key_combo_str, combo_key, binding.command_name)
            count = count + 1
        end
    end

    log.event("Loaded %d keybindings from %s", count, file_path)
end

--- Check if a context matches a list of allowed contexts.
-- Empty contexts list = global (always matches).
local function context_matches(allowed_contexts, active_context)
    if not allowed_contexts or #allowed_contexts == 0 then
        return true  -- global binding
    end
    for _, ctx in ipairs(allowed_contexts) do
        if ctx == active_context then return true end
    end
    return false
end

-- Handle a key event and execute matching command via TOML keybindings.
-- Iterates all bindings for the combo key; picks first context match.
-- Context-specific bindings are checked before global (no-context) bindings.
function M.handle_key_event(key, modifiers, context)
    -- Strip non-significant modifiers (KeypadModifier, GroupSwitchModifier)
    -- that Qt adds to arrow keys, numpad keys, etc.
    local bit = require("bit")
    modifiers = bit.band(modifiers, kb_constants.SIGNIFICANT_MOD_MASK)

    -- Qt6 shifted-symbol normalization: Qt reports Shift+` as key=Tilde+Shift.
    -- The Shift is redundant — Tilde IS the shifted Grave. Strip it so TOML
    -- bindings can use "Tilde" without requiring "Shift+Tilde".
    if kb_constants.SHIFTED_SYMBOL_KEYS[key]
        and bit.band(modifiers, kb_constants.MOD.Shift) ~= 0 then
        modifiers = bit.band(modifiers, bit.bnot(kb_constants.MOD.Shift))
    end

    local combo_key = string.format("%d_%d", key, modifiers)

    local bindings = M.keybindings[combo_key]
    if not bindings then
        log.detail("  no TOML binding for combo_key=%s", combo_key)
        return false
    end

    assert(command_manager,
        string.format("handle_key_event: command_manager not set (combo %s)", combo_key))

    -- Two passes: first try context-specific bindings, then global (no-context)
    local matched = nil
    for _, binding in ipairs(bindings) do
        if binding.contexts and #binding.contexts > 0 and context_matches(binding.contexts, context) then
            matched = binding
            break
        end
    end
    if not matched then
        for _, binding in ipairs(bindings) do
            if not binding.contexts or #binding.contexts == 0 then
                matched = binding
                break
            end
        end
    end

    if not matched then
        log.detail("  no context match for combo_key=%s active='%s'", combo_key, tostring(context))
        return false
    end

    log.detail("  context matched: combo_key=%s → command='%s' contexts={%s}",
        combo_key, matched.command_name,
        table.concat(matched.contexts or {}, ","))

    assert(command_manager.get_executor(matched.command_name),
        string.format("handle_key_event: TOML binding '%s' has no registered executor (combo %s)",
            matched.command_name, matched.shortcut and matched.shortcut.string or combo_key))

    local params = {}
    for k, v in pairs(matched.named_params) do
        params[k] = v
    end
    if #matched.positional_args > 0 then
        params._positional = matched.positional_args
    end

    log.detail("  dispatching %s via execute_interactive", matched.command_name)

    local result = command_manager.execute_interactive(matched.command_name, params)
    if result and not result.success and result.error_message then
        log.warn("%s: %s", matched.command_name, result.error_message)
    end
    return true
end

-------------------------------------------------------------------------------
-- QShortcut creation from TOML bindings
-------------------------------------------------------------------------------

-- Active QShortcut objects: {shortcut_userdata, handler_name}[]
M.active_shortcuts = nil

-- Handler counter for unique global function names
local handler_counter = 0

--- Map TOML key names to QKeySequence-compatible strings.
-- Most key names pass through unchanged (Space, Return, Delete, F1, etc.).
-- Symbol keys need their character form for QKeySequence.
local TOML_KEY_TO_QT = {
    Tilde       = "~",
    Grave       = "`",
    BracketLeft = "[",
    BracketRight = "]",
    BraceLeft   = "{",
    BraceRight  = "}",
    Equal       = "=",
    Plus        = "+",
    Minus       = "-",
    Comma       = ",",
    Period      = ".",
    Backspace   = "Backspace",
    -- Digit keys: keyboard_constants uses "Key2" etc., QKeySequence expects "2"
    Key2        = "2",
    Key3        = "3",
    Key4        = "4",
    -- Single letters, function keys, Space, Return, Delete,
    -- Home, End, Up, Down, Tab, Escape — all work as-is in QKeySequence
}

--- Convert a parsed shortcut (key code + modifiers) back to Qt QKeySequence string.
-- Used for shortcuts that went through parse_shortcut() normalization
-- (e.g., Shift+BracketLeft → BraceLeft with no Shift).
local function shortcut_to_qt_keyseq(shortcut_obj)
    local bit = require("bit")
    local KEY = kb_constants.KEY
    local MOD = kb_constants.MOD

    local qt_parts = {}

    -- Modifiers — order matters for QKeySequence but Qt is flexible
    if bit.band(shortcut_obj.modifiers, MOD.Control) ~= 0 then
        qt_parts[#qt_parts + 1] = "Ctrl"
    end
    if bit.band(shortcut_obj.modifiers, MOD.Alt) ~= 0 then
        qt_parts[#qt_parts + 1] = "Alt"
    end
    if bit.band(shortcut_obj.modifiers, MOD.Shift) ~= 0 then
        qt_parts[#qt_parts + 1] = "Shift"
    end
    if bit.band(shortcut_obj.modifiers, MOD.Meta) ~= 0 then
        qt_parts[#qt_parts + 1] = "Meta"
    end

    -- Key code → name
    -- First try reverse lookup in TOML_KEY_TO_QT values (symbol keys)
    local key_code = shortcut_obj.key
    local qt_key_name = nil

    -- Reverse lookup in KEY table to get TOML name, then map to Qt
    for name, code in pairs(KEY) do
        if code == key_code then
            qt_key_name = TOML_KEY_TO_QT[name] or name
            break
        end
    end

    -- Fall back to character for printable ASCII
    if not qt_key_name then
        if key_code >= 32 and key_code < 127 then
            qt_key_name = string.char(key_code)
        else
            assert(false, string.format(
                "shortcut_to_qt_keyseq: no Qt name for key code %d", key_code))
        end
    end

    qt_parts[#qt_parts + 1] = qt_key_name
    return table.concat(qt_parts, "+")
end

--- Create a Lua handler function for a QShortcut binding.
-- Registers as a global so the C++ QShortcut::activated signal can invoke it.
-- Returns the global function name.
local function create_shortcut_handler(binding)
    handler_counter = handler_counter + 1
    local name = string.format("__jve_shortcut_%d", handler_counter)

    _G[name] = function()
        assert(command_manager,
            string.format("shortcut handler %s: command_manager not set", binding.command_name))

        -- Wrap in command event (same as keyboard_shortcuts.handle_key)
        local owns_event = not command_manager.peek_command_event_origin()
        if owns_event then
            command_manager.begin_command_event("ui")
        end

        local params = {}
        for k, v in pairs(binding.named_params) do
            params[k] = v
        end
        if #binding.positional_args > 0 then
            params._positional = binding.positional_args
        end

        local ok, err = pcall(command_manager.execute_interactive, binding.command_name, params)

        if owns_event then
            command_manager.end_command_event()
        end

        if not ok then
            -- Fail loud per CLAUDE.md §1.14: no silent error handling
            assert(false, string.format(
                "shortcut handler %s: %s", binding.command_name, tostring(err)))
        end
    end

    return name
end

--- Create QShortcut objects from all loaded TOML bindings.
-- @param panel_containers table mapping context names to Qt widgets:
--   { window=main_window, timeline=timeline_container,
--     source_monitor=source_widget, timeline_monitor=tl_monitor_widget,
--     project_browser=browser_container }
function M.create_qt_shortcuts(panel_containers)
    assert(panel_containers, "create_qt_shortcuts: panel_containers required")
    assert(panel_containers.window, "create_qt_shortcuts: window container required")

    -- Clean up any existing shortcuts first
    M.destroy_qt_shortcuts()

    M.active_shortcuts = {}

    -- luacheck: globals qt_create_shortcut qt_connect_shortcut
    assert(type(qt_create_shortcut) == "function",
        "create_qt_shortcuts: qt_create_shortcut C++ binding not available")
    assert(type(qt_connect_shortcut) == "function",
        "create_qt_shortcuts: qt_connect_shortcut C++ binding not available")

    local count = 0
    for _, bindings in pairs(M.keybindings) do
        for _, binding in ipairs(bindings) do
            local qt_key_seq = shortcut_to_qt_keyseq(binding.shortcut)
            assert(qt_key_seq and qt_key_seq ~= "", string.format(
                "create_qt_shortcuts: empty key sequence for binding '%s'",
                binding.command_name))

            if not binding.contexts or #binding.contexts == 0 then
                -- Global binding: WindowShortcut on main window
                local sc = qt_create_shortcut(
                    panel_containers.window, qt_key_seq, "window")
                assert(sc, string.format(
                    "create_qt_shortcuts: qt_create_shortcut returned nil for '%s' (window)",
                    qt_key_seq))
                local handler_name = create_shortcut_handler(binding)
                qt_connect_shortcut(sc, handler_name)
                M.active_shortcuts[#M.active_shortcuts + 1] = {
                    shortcut = sc,
                    handler_name = handler_name,
                }
                count = count + 1
                log.detail("QShortcut: %s → %s (window)", qt_key_seq, binding.command_name)
            else
                -- Panel-scoped: one QShortcut per context
                for _, ctx in ipairs(binding.contexts) do
                    local container = panel_containers[ctx]
                    if container then
                        local sc = qt_create_shortcut(
                            container, qt_key_seq, "widget_children")
                        assert(sc, string.format(
                            "create_qt_shortcuts: qt_create_shortcut returned nil for '%s' (@%s)",
                            qt_key_seq, ctx))
                        local handler_name = create_shortcut_handler(binding)
                        qt_connect_shortcut(sc, handler_name)
                        M.active_shortcuts[#M.active_shortcuts + 1] = {
                            shortcut = sc,
                            handler_name = handler_name,
                        }
                        count = count + 1
                        log.detail("QShortcut: %s → %s (@%s)", qt_key_seq, binding.command_name, ctx)
                    else
                        assert(false, string.format(
                            "create_qt_shortcuts: no container for context '%s' (binding: %s)",
                            ctx, binding.command_name))
                    end
                end
            end
        end
    end

    log.event("Created %d QShortcut objects from TOML bindings", count)
end

--- Destroy all active QShortcut objects and clean up handler globals.
function M.destroy_qt_shortcuts()
    if not M.active_shortcuts then return end

    -- luacheck: globals qt_delete_shortcut
    for _, entry in ipairs(M.active_shortcuts) do
        if entry.shortcut then
            qt_delete_shortcut(entry.shortcut)
        end
        if entry.handler_name then
            _G[entry.handler_name] = nil
        end
    end

    log.event("Destroyed %d QShortcut objects", #M.active_shortcuts)
    M.active_shortcuts = nil
end

return M
