--- Find & Replace dialog: modal search-and-replace for clip properties.
--
-- Launched by Cmd+H. Provides field selector (editable columns only),
-- find/replace fields, scope selector, and Replace/Replace All/Skip cycling.
--
-- @file find_replace_dialog.lua

local qt = require("core.qt_constants")
local query_engine = require("core.query_engine")
local find_state = require("core.find_state")
local command_manager = require("core.command_manager")
local json = require("dkjson")

local M = {}

local SETTINGS_PATH = (os.getenv("HOME") or "") .. "/.jve/find_replace_dialog_settings.json"

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
-- Build editable fields list for combobox
-- ============================================================================

local function get_editable_field_names()
    local fields = query_engine.get_searchable_fields()
    local names = {}
    for _, f in ipairs(fields) do
        if f.editable then
            names[#names + 1] = f.name
        end
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
-- Internal: resolve scope clips
-- ============================================================================

local function get_scoped_clips(opts, scope)
    if scope == "selected" and opts.selected_clip_ids then
        local selected_set = {}
        for _, id in ipairs(opts.selected_clip_ids) do
            selected_set[id] = true
        end
        local scoped = {}
        for _, clip in ipairs(opts.clips) do
            if selected_set[clip.id] then
                scoped[#scoped + 1] = clip
            end
        end
        return scoped
    end
    return opts.clips
end

-- ============================================================================
-- Public: show find & replace dialog
-- ============================================================================

--- Show the Find & Replace dialog.
-- @param opts table {clips=array, project_id=string, selected_clip_ids=array_or_nil, on_replace=fn, on_navigate=fn}
-- @return table {action="replace"|"replace_all"|"cancel"}
function M.show(opts)
    assert(opts, "find_replace_dialog.show: opts required")
    assert(opts.clips, "find_replace_dialog.show: clips required")
    assert(opts.project_id, "find_replace_dialog.show: project_id required")

    local settings = load_settings()
    local globals = {}
    local result = nil

    local dialog = qt.DIALOG.CREATE("Find & Replace", 500, 260, nil)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- Row 1: Field selector (editable columns only)
    local field_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(field_row, qt.WIDGET.CREATE_LABEL("Field:"))
    local field_combo = qt.WIDGET.CREATE_COMBOBOX()
    local field_names = get_editable_field_names()
    for _, name in ipairs(field_names) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(field_combo, name)
    end
    if settings.last_field then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(field_combo, settings.last_field)
    end
    qt.LAYOUT.ADD_WIDGET(field_row, field_combo)
    qt.LAYOUT.ADD_LAYOUT(main_layout, field_row)

    -- Row 2: Operator selector
    local op_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(op_row, qt.WIDGET.CREATE_LABEL("Operator:"))
    local op_combo = qt.WIDGET.CREATE_COMBOBOX()
    local current_field = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(field_combo)
    local ops = get_operators_for_field(current_field)
    for _, op in ipairs(ops) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(op_combo, op)
    end
    if settings.last_operator then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(op_combo, settings.last_operator)
    end
    qt.LAYOUT.ADD_WIDGET(op_row, op_combo)
    qt.LAYOUT.ADD_LAYOUT(main_layout, op_row)

    -- Row 3: Find value
    local find_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(find_row, qt.WIDGET.CREATE_LABEL("Find:"))
    local find_edit = qt.WIDGET.CREATE_LINE_EDIT(settings.last_find or "")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(find_edit, "Find text...")
    qt.LAYOUT.ADD_WIDGET(find_row, find_edit)
    qt.LAYOUT.ADD_LAYOUT(main_layout, find_row)

    -- Row 4: Replace value
    local replace_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(replace_row, qt.WIDGET.CREATE_LABEL("Replace:"))
    local replace_edit = qt.WIDGET.CREATE_LINE_EDIT(settings.last_replace or "")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(replace_edit, "Replace with...")
    qt.LAYOUT.ADD_WIDGET(replace_row, replace_edit)
    qt.LAYOUT.ADD_LAYOUT(main_layout, replace_row)

    -- Row 5: Scope selector
    local scope_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(scope_row, qt.WIDGET.CREATE_LABEL("Scope:"))
    local scope_combo = qt.WIDGET.CREATE_COMBOBOX()
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(scope_combo, "All Visible")
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(scope_combo, "Selected Clips")
    if settings.last_scope then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(scope_combo, settings.last_scope)
    end
    -- Disable "Selected Clips" option when nothing selected
    if not opts.selected_clip_ids or #opts.selected_clip_ids == 0 then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(scope_combo, "All Visible")
    end
    qt.LAYOUT.ADD_WIDGET(scope_row, scope_combo)
    qt.LAYOUT.ADD_LAYOUT(main_layout, scope_row)

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- Helper: persist current settings
    local function persist_current()
        save_settings({
            last_field = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(field_combo),
            last_operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(op_combo),
            last_find = qt.PROPERTIES.GET_TEXT(find_edit),
            last_replace = qt.PROPERTIES.GET_TEXT(replace_edit),
            last_scope = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(scope_combo),
        })
    end

    -- Helper: resolve scope to "all" or "selected"
    local function get_scope()
        local scope_text = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(scope_combo)
        if scope_text == "Selected Clips" then return "selected" end
        return "all"
    end

    -- Helper: ensure find state is initialized for current query
    local function ensure_find_active()
        local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(field_combo)
        local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(op_combo)
        local find_value = qt.PROPERTIES.GET_TEXT(find_edit)
        if find_value == "" then return false end
        local scope = get_scope()
        local scoped_clips = get_scoped_clips(opts, scope)
        find_state.execute(scoped_clips,
            {column = column, operator = operator, value = find_value})
        return find_state.get_match_count() > 0
    end

    -- Buttons
    local btn_row = qt.LAYOUT.CREATE_HBOX()

    -- Replace (single)
    local replace_btn = qt.WIDGET.CREATE_BUTTON("Replace")
    local replace_name = "__find_replace_dialog_replace"
    _G[replace_name] = function()
        if not ensure_find_active() then return end
        local current_id = find_state.get_current_match()
        if not current_id then return end
        local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(field_combo)
        local replace_value = qt.PROPERTIES.GET_TEXT(replace_edit)
        command_manager.execute_interactive("ReplaceClipProperty", {
            clip_id = current_id,
            column = column,
            find_value = qt.PROPERTIES.GET_TEXT(find_edit),
            replace_value = replace_value,
            project_id = opts.project_id,
        })
        persist_current()
        result = {action = "replace"}
        if opts.on_replace then opts.on_replace(result) end
        -- Advance to next match
        find_state.next()
        if opts.on_navigate then
            opts.on_navigate(find_state.get_current_match(), find_state.get_current_index())
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(replace_btn, replace_name)
    globals[#globals + 1] = replace_name
    qt.LAYOUT.ADD_WIDGET(btn_row, replace_btn)

    -- Replace All
    local replace_all_btn = qt.WIDGET.CREATE_BUTTON("Replace All")
    local replace_all_name = "__find_replace_dialog_replace_all"
    _G[replace_all_name] = function()
        if not ensure_find_active() then return end
        local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(field_combo)
        local find_value = qt.PROPERTIES.GET_TEXT(find_edit)
        local replace_value = qt.PROPERTIES.GET_TEXT(replace_edit)
        local match_ids = find_state.get_matches()
        command_manager.execute_interactive("ReplaceAllClipProperties", {
            clip_ids = match_ids,
            column = column,
            find_value = find_value,
            replace_value = replace_value,
            project_id = opts.project_id,
        })
        persist_current()
        result = {action = "replace_all"}
        if opts.on_replace then opts.on_replace(result) end
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(replace_all_btn, replace_all_name)
    globals[#globals + 1] = replace_all_name
    qt.LAYOUT.ADD_WIDGET(btn_row, replace_all_btn)

    -- Skip
    local skip_btn = qt.WIDGET.CREATE_BUTTON("Skip")
    local skip_name = "__find_replace_dialog_skip"
    _G[skip_name] = function()
        if not find_state.is_active() then return end
        find_state.next()
        if opts.on_navigate then
            opts.on_navigate(find_state.get_current_match(), find_state.get_current_index())
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(skip_btn, skip_name)
    globals[#globals + 1] = skip_name
    qt.LAYOUT.ADD_WIDGET(btn_row, skip_btn)

    -- Close
    local close_btn = qt.WIDGET.CREATE_BUTTON("Close")
    local close_name = "__find_replace_dialog_close"
    _G[close_name] = function()
        persist_current()
        find_state.clear()
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
