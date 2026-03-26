--- Find dialog: modal search dialog for project browser and timeline.
--
-- Launched by Cmd+F. Context-aware: searches browser or timeline
-- based on focused panel. Provides attribute/operator/value fields,
-- scope selector, and Find Next/Previous cycling.
--
-- @file find_dialog.lua

local qt = require("core.qt_constants")
local query_engine = require("core.query_engine")
local find_state = require("core.find_state")
local sift_state = require("core.sift_state")
local json = require("dkjson")

local M = {}

local SETTINGS_PATH = (os.getenv("HOME") or "") .. "/.jve/find_dialog_settings.json"

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
-- Build searchable fields list for combobox
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
    -- Custom property — default to text operators
    return TEXT_OPERATORS
end

-- ============================================================================
-- Public: show find dialog
-- ============================================================================

--- Show the Find dialog.
-- @param opts table {clips=array, context="browser"|"timeline", project_id=string, on_find=fn, on_replace=fn}
-- @return table {action="find"|"replace"|"cancel", query={column,operator,value}, scope=string}
function M.show(opts)
    assert(opts, "find_dialog.show: opts required")
    assert(opts.clips, "find_dialog.show: clips required")

    local settings = load_settings()
    local globals = {}
    local result = nil

    local dialog = qt.DIALOG.CREATE("Find", 450, 200, nil)

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
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(val_edit, "Search text...")
    qt.LAYOUT.ADD_WIDGET(val_row, val_edit)
    qt.LAYOUT.ADD_LAYOUT(main_layout, val_row)

    -- Row 4: Scope selector (only when sift active)
    local scope_combo
    if sift_state.is_active() then
        local scope_row = qt.LAYOUT.CREATE_HBOX()
        qt.LAYOUT.ADD_WIDGET(scope_row, qt.WIDGET.CREATE_LABEL("Scope:"))
        scope_combo = qt.WIDGET.CREATE_COMBOBOX()
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(scope_combo, "All Clips")
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(scope_combo, "Visible (Sifted)")
        if settings.last_scope then
            qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(scope_combo, settings.last_scope)
        end
        qt.LAYOUT.ADD_WIDGET(scope_row, scope_combo)
        qt.LAYOUT.ADD_LAYOUT(main_layout, scope_row)
    end

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- Buttons
    local btn_row = qt.LAYOUT.CREATE_HBOX()

    local find_btn = qt.WIDGET.CREATE_BUTTON("Find")
    local find_name = "__find_dialog_find"
    _G[find_name] = function()
        local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo)
        local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(op_combo)
        local value = qt.PROPERTIES.GET_TEXT(val_edit)
        if value == "" then return end

        local scope = "all"
        if scope_combo then
            local scope_text = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(scope_combo)
            if scope_text == "Visible (Sifted)" then scope = "visible" end
        end

        -- Save selection before first find
        if not find_state.is_active() then
            -- UI layer saves current selection via opts.save_selection if provided
            if opts.save_selection then
                find_state.save_selection(opts.save_selection())
            end
        end

        -- Build hidden_ids for scope filtering
        local find_opts = {}
        if scope == "visible" and sift_state.is_active() then
            local eval = sift_state.evaluate(opts.clips)
            local hidden = {}
            for _, id in ipairs(eval.hidden_ids) do hidden[id] = true end
            find_opts.hidden_ids = hidden
        end

        find_state.execute(opts.clips, {column = column, operator = operator, value = value}, find_opts)

        result = {
            action = "find",
            query = {column = column, operator = operator, value = value},
            scope = scope,
            match_count = find_state.get_match_count(),
            current_match = find_state.get_current_match(),
        }

        -- Persist settings
        save_settings({
            last_column = column,
            last_operator = operator,
            last_value = value,
            last_scope = scope_combo and qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(scope_combo) or nil,
        })

        -- Notify caller
        if opts.on_find then opts.on_find(result) end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(find_btn, find_name)
    globals[#globals + 1] = find_name
    qt.LAYOUT.ADD_WIDGET(btn_row, find_btn)

    -- Find Next
    local next_btn = qt.WIDGET.CREATE_BUTTON("Find Next")
    local next_name = "__find_dialog_next"
    _G[next_name] = function()
        if not find_state.is_active() then return end
        find_state.next()
        if opts.on_navigate then
            opts.on_navigate(find_state.get_current_match(), find_state.get_current_index())
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(next_btn, next_name)
    globals[#globals + 1] = next_name
    qt.LAYOUT.ADD_WIDGET(btn_row, next_btn)

    -- Find Previous
    local prev_btn = qt.WIDGET.CREATE_BUTTON("Find Previous")
    local prev_name = "__find_dialog_prev"
    _G[prev_name] = function()
        if not find_state.is_active() then return end
        find_state.previous()
        if opts.on_navigate then
            opts.on_navigate(find_state.get_current_match(), find_state.get_current_index())
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(prev_btn, prev_name)
    globals[#globals + 1] = prev_name
    qt.LAYOUT.ADD_WIDGET(btn_row, prev_btn)

    -- Find & Replace button (FR-011b)
    local replace_btn = qt.WIDGET.CREATE_BUTTON("Find & Replace...")
    local replace_name = "__find_dialog_replace"
    _G[replace_name] = function()
        result = {action = "replace"}
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(replace_btn, replace_name)
    globals[#globals + 1] = replace_name
    qt.LAYOUT.ADD_WIDGET(btn_row, replace_btn)

    -- Close
    local close_btn = qt.WIDGET.CREATE_BUTTON("Close")
    local close_name = "__find_dialog_close"
    _G[close_name] = function()
        -- Restore previous selection (FR-016)
        if find_state.is_active() then
            local prev = find_state.get_previous_selection()
            if opts.on_restore_selection and prev then
                opts.on_restore_selection(prev)
            end
            find_state.clear()
        end
        result = {action = "cancel"}
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(close_btn, close_name)
    globals[#globals + 1] = close_name
    qt.LAYOUT.ADD_WIDGET(btn_row, close_btn)

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
