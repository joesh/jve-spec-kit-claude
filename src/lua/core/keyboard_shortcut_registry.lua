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
local store = require("core.user_keymap_store")

-- Default preset name (sentinel; not stored on disk — represents the bundled keymap)
M.DEFAULT_PRESET = "Default"

-- Command registry: all commands that can have shortcuts (for shortcut editor UI)
-- Format: {id, category, name, description, current_shortcuts}
M.commands = {}

-- TOML-based keybindings: {combo_key} -> array of {command_name, positional_args, named_params, contexts, category, shortcut}
-- Multiple bindings per combo key supported — handle_key_event picks first context match.
-- Single source of truth for all keybindings. Populated by load_keybindings().
M.keybindings = {}

-- Path to the bundled default keymap (for reset_to_defaults).
-- Set ONLY when loading the bundled default, never when loading a preset
-- (presets are loaded from temp files that get deleted).
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

-- Assign a shortcut to a command (writes to keybindings).
-- options.force = true overwrites any existing binding on the same combo
-- (Premiere-style "warn + overwrite"). Default: refuse if conflict exists.
-- options.contexts = array of context strings (e.g. {"timeline"}); empty/nil = global.
-- Returns: success, error_message_or_conflict_command_id
function M.assign_shortcut(command_id, shortcut_string, options)
    options = options or {}
    local command = M.commands[command_id]
    if not command then
        return false, string.format("Unknown command: %s", command_id)
    end

    local shortcut, err = M.parse_shortcut(shortcut_string)
    if not shortcut then
        return false, err
    end

    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)

    -- Conflict check: refuse unless force=true. Returns conflict id so caller
    -- can decide how to surface it (e.g. confirmation dialog).
    local conflict = M.find_conflict(shortcut.key, shortcut.modifiers)
    if conflict and conflict ~= command_id and not options.force then
        local conflict_name = (M.commands[conflict] and M.commands[conflict].name) or conflict
        return false,
            string.format("Shortcut already assigned to: %s", conflict_name),
            conflict
    end

    -- Remove the entire combo entry (any prior binding on this combo, regardless
    -- of which command it pointed at). assign_shortcut is the single-binding
    -- assignment path; multi-binding setups must call this once per binding.
    if M.keybindings[combo_key] then
        for _, prior in ipairs(M.keybindings[combo_key]) do
            local prior_cmd = M.commands[prior.command_name]
            if prior_cmd then
                for i, sc in ipairs(prior_cmd.current_shortcuts) do
                    if sc.key == shortcut.key and sc.modifiers == shortcut.modifiers then
                        table.remove(prior_cmd.current_shortcuts, i)
                        break
                    end
                end
            end
        end
        M.keybindings[combo_key] = nil
    end

    -- Cache shortcut on the command (kept in sync with M.keybindings; the
    -- derived view M.get_command_shortcuts() reads from M.keybindings and is
    -- the canonical read path for new code).
    table.insert(command.current_shortcuts, shortcut)

    -- Write to keybindings (single source of truth)
    M.keybindings[combo_key] = {{
        command_name = command_id,
        named_params = {},
        positional_args = {},
        contexts = options.contexts or {},
        category = command.category,
        shortcut = shortcut,
    }}

    M.rebuild_qt_shortcuts()
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

    M.rebuild_qt_shortcuts()
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

-- ---- TOML serialization (M.keybindings → TOML string) -------------------
--
-- Inverse of load_keybindings: produces the same TOML format the on-disk
-- keymap files use (see keymaps/default.jvekeys), so save→load is a true
-- round-trip. Bindings are grouped by their category (the [Section] header
-- they originally lived under).
local function format_value(binding)
    local parts = { binding.command_name }
    for _, arg in ipairs(binding.positional_args or {}) do
        parts[#parts + 1] = arg
    end
    for k, v in pairs(binding.named_params or {}) do
        parts[#parts + 1] = string.format("%s=%s", k, tostring(v))
    end
    for _, ctx in ipairs(binding.contexts or {}) do
        parts[#parts + 1] = "@" .. ctx
    end
    local value = table.concat(parts, " ")
    assert(not value:find('"'), "format_value: command/context contains a double-quote: " .. value)
    return value
end

function M.serialize_to_toml()
    -- Group bindings by category. Each binding stores its shortcut + category;
    -- the combo string is recovered via format_shortcut() (canonical form).
    local by_category = {}
    for _, bindings in pairs(M.keybindings) do
        for _, binding in ipairs(bindings) do
            assert(binding.category,
                "serialize_to_toml: binding for '" .. binding.command_name
                .. "' has no category (load_keybindings/assign_shortcut must set it)")
            local cat = binding.category
            by_category[cat] = by_category[cat] or {}
            local combo = M.format_shortcut(binding.shortcut.key, binding.shortcut.modifiers)
            by_category[cat][#by_category[cat] + 1] = {
                combo = combo,
                value = format_value(binding),
            }
        end
    end

    -- Stable ordering: alphabetical sections, alphabetical keys within
    local section_names = {}
    for name in pairs(by_category) do section_names[#section_names + 1] = name end
    table.sort(section_names)

    local out = {}
    for _, section in ipairs(section_names) do
        out[#out + 1] = string.format("[%s]", section)
        local entries = by_category[section]
        table.sort(entries, function(a, b) return a.combo < b.combo end)
        for _, entry in ipairs(entries) do
            out[#out + 1] = string.format('"%s" = "%s"', entry.combo, entry.value)
        end
        out[#out + 1] = ""  -- blank line between sections
    end
    return table.concat(out, "\n")
end

-- ---- Derived view: shortcuts for a command (single source of truth) ------
--
-- Reads from M.keybindings (canonical store). Avoids the staleness bug
-- where command.current_shortcuts isn't populated by load_keybindings.
function M.get_command_shortcuts(command_id)
    local results = {}
    for _, bindings in pairs(M.keybindings) do
        for _, binding in ipairs(bindings) do
            if binding.command_name == command_id then
                results[#results + 1] = {
                    key = binding.shortcut.key,
                    modifiers = binding.shortcut.modifiers,
                    string = M.format_shortcut(binding.shortcut.key, binding.shortcut.modifiers),
                    contexts = binding.contexts or {},
                }
            end
        end
    end
    table.sort(results, function(a, b) return a.string < b.string end)
    return results
end

-- ---- Disk-backed presets (write through user_keymap_store) ---------------

function M.save_preset(preset_name)
    assert(type(preset_name) == "string" and preset_name ~= "",
        "save_preset: preset_name required")
    assert(preset_name ~= M.DEFAULT_PRESET,
        "save_preset: cannot overwrite the bundled Default preset; use Save As")
    store.write(preset_name, M.serialize_to_toml())
    M.current_preset = preset_name
    return true
end

function M.load_preset(preset_name)
    assert(type(preset_name) == "string" and preset_name ~= "",
        "load_preset: preset_name required")

    if preset_name == M.DEFAULT_PRESET then
        return M.reset_to_defaults()
    end

    if not store.exists(preset_name) then
        return false, string.format("Preset not found: %s", preset_name)
    end

    -- Read into a temp file so we can reuse load_keybindings (which expects a path).
    -- Preserve loaded_toml_path so reset_to_defaults still points at the bundled default.
    local saved_default = M.loaded_toml_path
    local content = store.read(preset_name)
    local tmp = string.format("/tmp/jve_preset_load_%d.jvekeys", os.time())
    local f, err = io.open(tmp, "w")
    assert(f, string.format("load_preset: cannot write temp file: %s", tostring(err)))
    f:write(content); f:close()

    M.keybindings = {}
    M.load_keybindings(tmp)
    os.remove(tmp)
    M.loaded_toml_path = saved_default

    M.current_preset = preset_name
    M.rebuild_qt_shortcuts()
    return true
end

function M.delete_preset(preset_name)
    assert(preset_name ~= M.DEFAULT_PRESET,
        "delete_preset: cannot delete bundled Default preset")
    store.delete(preset_name)
    if store.get_active() == preset_name then
        store.set_active(nil)
    end
end

function M.list_presets()
    local presets = { M.DEFAULT_PRESET }
    for _, name in ipairs(store.list()) do
        presets[#presets + 1] = name
    end
    return presets
end

function M.get_active_preset()
    return store.get_active()
end

function M.set_active_preset(preset_name)
    if preset_name == nil or preset_name == M.DEFAULT_PRESET then
        store.set_active(nil)
        return
    end
    assert(store.exists(preset_name),
        string.format("set_active_preset: '%s' does not exist on disk", preset_name))
    store.set_active(preset_name)
end

-- Convenience: load the active preset if any, otherwise the bundled default.
-- Caller (keyboard_shortcuts.init) hands us the bundled-default path.
function M.load_active_or_default(default_path)
    assert(type(default_path) == "string", "load_active_or_default: default_path required")
    -- Always set loaded_toml_path to the bundled default so reset_to_defaults works,
    -- even when an active preset is loaded.
    local active = store.get_active()
    if active and store.exists(active) then
        local content = store.read(active)
        local tmp = string.format("/tmp/jve_active_preset_%d.jvekeys", os.time())
        local f = assert(io.open(tmp, "w"))
        f:write(content); f:close()
        M.load_keybindings(tmp)
        os.remove(tmp)
        M.loaded_toml_path = default_path
        M.current_preset = active
    else
        M.load_keybindings(default_path)
        M.current_preset = M.DEFAULT_PRESET
    end
end

-- Reset to defaults: re-load the bundled default TOML, clear active-preset
-- pointer, and rewire live QShortcuts.
function M.reset_to_defaults()
    assert(M.loaded_toml_path, "reset_to_defaults: no TOML file loaded yet")

    for _, command in pairs(M.commands) do
        command.current_shortcuts = {}
    end
    M.keybindings = {}

    M.load_keybindings(M.loaded_toml_path)
    M.current_preset = M.DEFAULT_PRESET
    store.set_active(nil)
    M.rebuild_qt_shortcuts()
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

-- Cached panel containers passed to create_qt_shortcuts. Used by
-- rebuild_qt_shortcuts so the dialog can rewire live QShortcuts after
-- assign/remove/load_preset without the caller re-supplying widget refs.
M._panel_containers = nil

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

    -- Cache so rebuild_qt_shortcuts can rewire after live edits.
    M._panel_containers = panel_containers

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

--- Rebuild all live QShortcut objects from the current M.keybindings.
-- Call after assign_shortcut / remove_shortcut / load_preset / reset_to_defaults
-- so Qt-level dispatch matches the in-memory keymap.
-- No-op if create_qt_shortcuts was never called (e.g. headless tests).
function M.rebuild_qt_shortcuts()
    if not M._panel_containers then
        return  -- Headless / pre-init: nothing to rewire
    end
    M.create_qt_shortcuts(M._panel_containers)
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
