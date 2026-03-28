--- Smart bin dialog: modal for creating/editing smart bins.
--
-- Provides name, scope, and dynamic criteria rows with
-- attribute/operator/value fields.
--
-- @file smart_bin_dialog.lua

local qt = require("core.qt_constants")
local query_engine = require("core.query_engine")
local json = require("dkjson")

local M = {}

local TEXT_OPERATORS = {"contains", "begins_with", "ends_with", "matches_exactly"}
local NUMERIC_OPERATORS = {"equals", "greater_than", "less_than"}

local function get_field_names()
    local fields = query_engine.get_searchable_fields()
    local names = {}
    for _, f in ipairs(fields) do
        names[#names + 1] = f.name
    end
    return names
end

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
-- Criteria row management
-- ============================================================================

local function add_criterion_row(criteria_layout, rows, globals, field_names, initial)
    local row_layout = qt.LAYOUT.CREATE_HBOX()

    -- Attribute combobox
    local attr_combo = qt.WIDGET.CREATE_COMBOBOX()
    for _, name in ipairs(field_names) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(attr_combo, name)
    end
    if initial and initial.column then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(attr_combo, initial.column)
    end
    qt.LAYOUT.ADD_WIDGET(row_layout, attr_combo)

    -- Operator combobox
    local op_combo = qt.WIDGET.CREATE_COMBOBOX()
    local current_field = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo)
    local ops = get_operators_for_field(current_field)
    for _, op in ipairs(ops) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(op_combo, op)
    end
    if initial and initial.operator then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(op_combo, initial.operator)
    end
    qt.LAYOUT.ADD_WIDGET(row_layout, op_combo)

    -- Value line edit
    local val_edit = qt.WIDGET.CREATE_LINE_EDIT((initial and initial.value) or "")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(val_edit, "Value...")
    qt.LAYOUT.ADD_WIDGET(row_layout, val_edit)

    -- Remove button
    local remove_btn = qt.WIDGET.CREATE_BUTTON("-")
    qt.LAYOUT.ADD_WIDGET(row_layout, remove_btn)

    local row_index = #rows + 1
    local row_entry = {
        layout = row_layout,
        attr_combo = attr_combo,
        op_combo = op_combo,
        val_edit = val_edit,
        remove_btn = remove_btn,
        removed = false,
    }
    rows[row_index] = row_entry

    -- Remove handler
    local remove_name = "__smart_bin_remove_" .. row_index
    _G[remove_name] = function()
        row_entry.removed = true
        qt.DISPLAY.SET_VISIBLE(attr_combo, false)
        qt.DISPLAY.SET_VISIBLE(op_combo, false)
        qt.DISPLAY.SET_VISIBLE(val_edit, false)
        qt.DISPLAY.SET_VISIBLE(remove_btn, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(remove_btn, remove_name)
    globals[#globals + 1] = remove_name

    qt.LAYOUT.ADD_LAYOUT(criteria_layout, row_layout)

    return row_entry
end

local function collect_criteria(rows)
    local criteria = {}
    for _, row in ipairs(rows) do
        if not row.removed then
            local value = qt.PROPERTIES.GET_TEXT(row.val_edit)
            if value ~= "" then
                criteria[#criteria + 1] = {
                    column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(row.attr_combo),
                    operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(row.op_combo),
                    value = value,
                }
            end
        end
    end
    return criteria
end

-- ============================================================================
-- Core dialog builder
-- ============================================================================

local function show_dialog(opts, editing)
    assert(opts, "smart_bin_dialog: opts required")

    local bins = opts.bins or {}
    local globals = {}
    local result = nil
    local rows = {}

    local title = editing and "Edit Smart Bin" or "New Smart Bin"
    local dialog = qt.DIALOG.CREATE(title, 550, 400, nil)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- Name field
    local name_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(name_row, qt.WIDGET.CREATE_LABEL("Name:"))
    local initial_name = ""
    if editing and opts.smart_bin then
        initial_name = opts.smart_bin.name or ""
    end
    local name_edit = qt.WIDGET.CREATE_LINE_EDIT(initial_name)
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(name_edit, "Smart bin name...")
    qt.LAYOUT.ADD_WIDGET(name_row, name_edit)
    qt.LAYOUT.ADD_LAYOUT(main_layout, name_row)

    -- Scope selector
    local scope_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(scope_row, qt.WIDGET.CREATE_LABEL("Scope:"))
    local scope_combo = qt.WIDGET.CREATE_COMBOBOX()
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(scope_combo, "Entire Project")
    for _, bin in ipairs(bins) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(scope_combo, bin.name)
    end
    if editing and opts.smart_bin and opts.smart_bin.scope_bin_id then
        for _, bin in ipairs(bins) do
            if bin.id == opts.smart_bin.scope_bin_id then
                qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(scope_combo, bin.name)
                break
            end
        end
    end
    qt.LAYOUT.ADD_WIDGET(scope_row, scope_combo)
    qt.LAYOUT.ADD_LAYOUT(main_layout, scope_row)

    qt.LAYOUT.ADD_SPACING(main_layout, 8)

    -- Criteria section
    qt.LAYOUT.ADD_WIDGET(main_layout, qt.WIDGET.CREATE_LABEL("Criteria:"))
    local criteria_layout = qt.LAYOUT.CREATE_VBOX()
    local field_names = get_field_names()

    -- Pre-populate criteria for edit mode
    if editing and opts.smart_bin and opts.smart_bin.criteria_json then
        local existing = json.decode(opts.smart_bin.criteria_json)
        if existing and type(existing) == "table" then
            for _, crit in ipairs(existing) do
                add_criterion_row(criteria_layout, rows, globals, field_names, crit)
            end
        end
    end

    -- Always start with at least one row
    if #rows == 0 then
        add_criterion_row(criteria_layout, rows, globals, field_names, nil)
    end

    qt.LAYOUT.ADD_LAYOUT(main_layout, criteria_layout)

    -- Add Criterion button
    local add_btn = qt.WIDGET.CREATE_BUTTON("Add Criterion")
    local add_name = "__smart_bin_add_criterion"
    _G[add_name] = function()
        add_criterion_row(criteria_layout, rows, globals, field_names, nil)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(add_btn, add_name)
    globals[#globals + 1] = add_name
    qt.LAYOUT.ADD_WIDGET(main_layout, add_btn)

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- Error label
    local error_label = qt.WIDGET.CREATE_LABEL("")
    qt.PROPERTIES.SET_STYLE(error_label, "color: #ff6666;")
    qt.DISPLAY.SET_VISIBLE(error_label, false)
    qt.LAYOUT.ADD_WIDGET(main_layout, error_label)

    -- Button box
    local button_box = qt.CONTROL.CREATE_BUTTON_BOX()
    qt.CONTROL.BUTTON_BOX_ADD(button_box, "OK", "accept")
    qt.CONTROL.BUTTON_BOX_ADD(button_box, "Cancel", "reject")
    qt.LAYOUT.ADD_WIDGET(main_layout, button_box)

    local cancel_name = "__smart_bin_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.BUTTON_BOX_SET_HANDLER(button_box, "rejected", cancel_name)
    globals[#globals + 1] = cancel_name

    local ok_name = "__smart_bin_ok"
    _G[ok_name] = function()
        local name = qt.PROPERTIES.GET_TEXT(name_edit)
        if name == "" then
            qt.PROPERTIES.SET_TEXT(error_label, "Name is required")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        local criteria = collect_criteria(rows)
        if #criteria == 0 then
            qt.PROPERTIES.SET_TEXT(error_label, "At least one criterion with a value is required")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        -- Resolve scope
        local scope_text = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(scope_combo)
        local scope_bin_id = nil
        if scope_text ~= "Entire Project" then
            for _, bin in ipairs(bins) do
                if bin.name == scope_text then
                    scope_bin_id = bin.id
                    break
                end
            end
        end

        result = {
            name = name,
            criteria_json = json.encode(criteria),
            scope_bin_id = scope_bin_id,
        }
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.BUTTON_BOX_SET_HANDLER(button_box, "accepted", ok_name)
    globals[#globals + 1] = ok_name

    -- Show (blocking)
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    qt.DIALOG.SHOW(dialog)

    -- Cleanup
    for _, gname in ipairs(globals) do
        _G[gname] = nil
    end

    return result
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Show dialog for creating a new smart bin.
-- @param opts table {project_id=string, bins=array_of_{id,name}}
-- @return table {name, criteria_json, scope_bin_id} or nil if cancelled
function M.show_create(opts)
    return show_dialog(opts, false)
end

--- Show dialog for editing an existing smart bin.
-- @param opts table {smart_bin=record, bins=array_of_{id,name}}
-- @return table {name, criteria_json, scope_bin_id} or nil if cancelled
function M.show_edit(opts)
    assert(opts.smart_bin, "smart_bin_dialog.show_edit: smart_bin required")
    return show_dialog(opts, true)
end

return M
