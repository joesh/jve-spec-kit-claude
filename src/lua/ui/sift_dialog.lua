--- Sift dialog: modal filtering dialog for project browser.
--
-- Launched by Cmd+Shift+F. Shows attribute/operator/value fields
-- with context-aware buttons based on whether a sift is active.
--
-- @file sift_dialog.lua

local qt = require("core.qt_constants")
local query_engine = require("core.query_engine")
local sift_state = require("core.sift_state")
local sift_commands = require("core.sift_commands")
local json = require("dkjson")

local M = {}

local SETTINGS_PATH = (os.getenv("HOME") or "") .. "/.jve/sift_dialog_settings.json"

-- ============================================================================
-- Settings persistence
-- ============================================================================

local function load_settings()
    local f = io.open(SETTINGS_PATH, "r")
    if not f then return {} end
    local raw = f:read("*a")
    f:close()
    return json.decode(raw) or {}
end

local function save_settings(settings)
    local dir = (os.getenv("HOME") or "") .. "/.jve"
    os.execute("mkdir -p " .. dir)
    local f = io.open(SETTINGS_PATH, "w")
    if f then
        f:write(json.encode(settings))
        f:close()
    end
end

-- ============================================================================
-- Build field/operator lists (shared with find_dialog)
-- ============================================================================

local function get_field_names()
    local fields = query_engine.get_searchable_fields()
    local names = {}
    for _, f in ipairs(fields) do
        names[#names + 1] = f.name
    end
    return names
end

local TEXT_OPERATORS = {"contains", "begins_with", "ends_with", "matches_exactly"}
local NUMERIC_OPERATORS = {"equals", "greater_than", "less_than"}

local function get_operators_for_field(field_name)
    local fields = query_engine.get_searchable_fields()
    for _, f in ipairs(fields) do
        if f.name == field_name then
            if f.type == "numeric" or f.type == "boolean" then
                return NUMERIC_OPERATORS
            end
            return TEXT_OPERATORS
        end
    end
    return TEXT_OPERATORS
end

-- ============================================================================
-- Internal: build query from current widget state
-- ============================================================================

local function build_query(attr_combo, op_combo, val_edit)
    local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo)
    local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(op_combo)
    local value = qt.PROPERTIES.GET_TEXT(val_edit)
    return {column = column, operator = operator, value = value}
end

-- ============================================================================
-- Public: show sift dialog
-- ============================================================================

--- Show the Sift dialog.
-- @param opts table {clips=array, db=connection, project_id=string, on_sift=fn}
-- @return table {action="sift"|"expand"|"narrow"|"clear"|"cancel", query={...}}
function M.show(opts)
    assert(opts, "sift_dialog.show: opts required")
    assert(opts.clips, "sift_dialog.show: clips required")
    assert(opts.db, "sift_dialog.show: db required")
    assert(opts.project_id, "sift_dialog.show: project_id required")

    local settings = load_settings()
    local globals = {}
    local result = nil
    local sift_active = sift_state.is_active()

    local dialog = qt.DIALOG.CREATE("Sift", 450, 220, nil)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- Row 1: Attribute selector
    local attr_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(attr_row, qt.WIDGET.CREATE_LABEL("Attribute:"))
    local attr_combo = qt.WIDGET.CREATE_COMBOBOX()
    local field_names = get_field_names()
    for _, name in ipairs(field_names) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(attr_combo, name)
    end
    if settings.last_column then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(attr_combo, settings.last_column)
    end
    qt.LAYOUT.ADD_WIDGET(attr_row, attr_combo)
    qt.LAYOUT.ADD_LAYOUT(main_layout, attr_row)

    -- Row 2: Operator selector
    local op_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(op_row, qt.WIDGET.CREATE_LABEL("Operator:"))
    local op_combo = qt.WIDGET.CREATE_COMBOBOX()
    local current_field = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo)
    local ops = get_operators_for_field(current_field)
    for _, op in ipairs(ops) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(op_combo, op)
    end
    if settings.last_operator then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(op_combo, settings.last_operator)
    end
    qt.LAYOUT.ADD_WIDGET(op_row, op_combo)
    qt.LAYOUT.ADD_LAYOUT(main_layout, op_row)

    -- Row 3: Search value
    local val_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(val_row, qt.WIDGET.CREATE_LABEL("Value:"))
    local val_edit = qt.WIDGET.CREATE_LINE_EDIT(settings.last_value or "")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(val_edit, "Filter text...")
    qt.LAYOUT.ADD_WIDGET(val_row, val_edit)
    qt.LAYOUT.ADD_LAYOUT(main_layout, val_row)

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- Buttons
    local btn_row = qt.LAYOUT.CREATE_HBOX()

    -- Helper to persist settings and close
    local function persist_and_close(action, query)
        save_settings({
            last_column = query and query.column or settings.last_column,
            last_operator = query and query.operator or settings.last_operator,
            last_value = query and query.value or settings.last_value,
        })
        result = {action = action, query = query}
        if opts.on_sift then opts.on_sift(result) end
        qt.DIALOG.CLOSE(dialog, true)
    end

    -- Sift button (always visible — applies fresh sift)
    local sift_btn = qt.WIDGET.CREATE_BUTTON("Sift")
    local sift_name = "__sift_dialog_sift"
    _G[sift_name] = function()
        local query = build_query(attr_combo, op_combo, val_edit)
        if query.value == "" then return end
        sift_commands.sift(opts.clips, query, opts.db, opts.project_id)
        persist_and_close("sift", query)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(sift_btn, sift_name)
    globals[#globals + 1] = sift_name
    qt.LAYOUT.ADD_WIDGET(btn_row, sift_btn)

    -- Expand/Narrow/Clear only when sift active
    if sift_active then
        local expand_btn = qt.WIDGET.CREATE_BUTTON("Expand Sift")
        local expand_name = "__sift_dialog_expand"
        _G[expand_name] = function()
            local query = build_query(attr_combo, op_combo, val_edit)
            if query.value == "" then return end
            sift_commands.expand_sift(opts.clips, query, opts.db, opts.project_id)
            persist_and_close("expand", query)
        end
        qt.CONTROL.SET_BUTTON_CLICK_HANDLER(expand_btn, expand_name)
        globals[#globals + 1] = expand_name
        qt.LAYOUT.ADD_WIDGET(btn_row, expand_btn)

        local narrow_btn = qt.WIDGET.CREATE_BUTTON("Narrow Sift")
        local narrow_name = "__sift_dialog_narrow"
        _G[narrow_name] = function()
            local query = build_query(attr_combo, op_combo, val_edit)
            if query.value == "" then return end
            sift_commands.narrow_sift(opts.clips, query, opts.db, opts.project_id)
            persist_and_close("narrow", query)
        end
        qt.CONTROL.SET_BUTTON_CLICK_HANDLER(narrow_btn, narrow_name)
        globals[#globals + 1] = narrow_name
        qt.LAYOUT.ADD_WIDGET(btn_row, narrow_btn)

        local clear_btn = qt.WIDGET.CREATE_BUTTON("Clear Sift")
        local clear_name = "__sift_dialog_clear"
        _G[clear_name] = function()
            sift_commands.clear_sift(opts.db, opts.project_id)
            result = {action = "clear", query = nil}
            if opts.on_sift then opts.on_sift(result) end
            qt.DIALOG.CLOSE(dialog, true)
        end
        qt.CONTROL.SET_BUTTON_CLICK_HANDLER(clear_btn, clear_name)
        globals[#globals + 1] = clear_name
        qt.LAYOUT.ADD_WIDGET(btn_row, clear_btn)
    end

    -- Cancel
    local cancel_btn = qt.WIDGET.CREATE_BUTTON("Cancel")
    local cancel_name = "__sift_dialog_cancel"
    _G[cancel_name] = function()
        result = {action = "cancel", query = nil}
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(cancel_btn, cancel_name)
    globals[#globals + 1] = cancel_name
    qt.LAYOUT.ADD_WIDGET(btn_row, cancel_btn)

    qt.LAYOUT.ADD_LAYOUT(main_layout, btn_row)

    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    qt.DIALOG.SHOW(dialog)

    -- Cleanup
    for _, name in ipairs(globals) do
        _G[name] = nil
    end

    return result
end

return M
