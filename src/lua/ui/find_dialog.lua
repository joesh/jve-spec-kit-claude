--- Unified Find & Filter dialog: non-modal floating window.
--
-- Pure view: renders query controls and dispatches commands.
-- All find execution, navigation, and selection logic lives in
-- core/commands/find_clips.lua. The dialog owns only its widgets
-- and settings persistence.
--
-- @file find_dialog.lua
-- luacheck: globals qt_set_line_edit_return_pressed_handler qt_set_line_edit_text_changed_handler qt_create_single_shot_timer

local qt = require("core.qt_constants")
local query_engine = require("core.query_engine")
local command_manager = require("core.command_manager")
local db_module = require("core.database")
local dialog_prefs = require("core.dialog_prefs")
local log = require("core.logger").for_area("ui.find")

local M = {}

local SETTINGS_PATH = dialog_prefs.path_for("find_dialog_settings.json")
local GEOMETRY_KEY = "find_dialog_geometry"

-- ============================================================================
-- Window state (persists across show/hide)
-- ============================================================================

local ws = {
    window = nil,
    attr_combo = nil,
    op_combo = nil,
    find_edit = nil,
    replace_edit = nil,
    replace_label = nil,
    scope_combo = nil,
    status_label = nil,
    rep_btn = nil,
    rep_all_btn = nil,
    geometry_ready = false,
    bool_field = false,
    visible = false,
}

-- ============================================================================
-- Settings persistence
-- ============================================================================

local function load_settings()
    return dialog_prefs.load(SETTINGS_PATH)
end

local function save_settings(settings)
    dialog_prefs.save(SETTINGS_PATH, settings)
end

local function save_window_geometry()
    if not ws.window or not ws.geometry_ready then return end
    local project_id = db_module.get_current_project_id()
    if not project_id then return end
    local x, y, w, h = qt.PROPERTIES.GET_GEOMETRY(ws.window)
    if w < 50 or h < 50 then return end
    db_module.set_project_setting(project_id, GEOMETRY_KEY, {x = x, y = y, width = w, height = h})
end

-- ============================================================================
-- Field helpers
-- ============================================================================

local TEXT_OPERATORS = {"contains", "begins_with", "ends_with", "matches_exactly"}
local NUMERIC_OPERATORS = {"equals", "greater_than", "less_than"}
local BOOLEAN_VALUES = {"true", "false"}

local function field_type_for(field_name)
    local fields = query_engine.get_searchable_fields()
    for _, f in ipairs(fields) do
        if f.name == field_name then return f.type end
    end
    return "text"
end

local function populate_operators(field_name)
    if not ws.op_combo then return end
    local ftype = field_type_for(field_name)
    ws.bool_field = (ftype == "boolean")
    qt.PROPERTIES.CLEAR_COMBOBOX(ws.op_combo)
    if ws.bool_field then
        for _, v in ipairs(BOOLEAN_VALUES) do
            qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.op_combo, v)
        end
    elseif ftype == "numeric" then
        for _, op in ipairs(NUMERIC_OPERATORS) do
            qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.op_combo, op)
        end
    else
        for _, op in ipairs(TEXT_OPERATORS) do
            qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.op_combo, op)
        end
    end
end

local function get_find_operator()
    if ws.bool_field then return "equals" end
    return qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.op_combo)
end

local function get_find_value()
    if ws.bool_field then
        return qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.op_combo)
    end
    return qt.PROPERTIES.GET_TEXT(ws.find_edit)
end

-- ============================================================================
-- Status bar
-- ============================================================================

function M.update_status(text)
    if ws.status_label then
        qt.PROPERTIES.SET_TEXT(ws.status_label, text)
    end
end

-- ============================================================================
-- Build query args from current widget state
-- ============================================================================

local function get_query_args()
    return {
        column   = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo),
        operator = get_find_operator(),
        value    = get_find_value(),
    }
end

local function has_query_value(args)
    return ws.bool_field or (args.value and args.value ~= "")
end

local function has_replace_text()
    if not ws.replace_edit then return false end
    local text = qt.PROPERTIES.GET_TEXT(ws.replace_edit)
    return text and text ~= ""
end

-- ============================================================================
-- Button actions — dispatch commands only
-- ============================================================================

local function do_find()
    local args = get_query_args()
    if not has_query_value(args) then M.update_status("Enter search text"); return end
    save_settings({
        last_column  = args.column,
        last_operator = not ws.bool_field and args.operator or nil,
        last_value   = not ws.bool_field and args.value or nil,
        last_replace = qt.PROPERTIES.GET_TEXT(ws.replace_edit),
    })
    command_manager.execute_interactive("Find", args)
end

local function do_find_next()
    local args = get_query_args()
    if not has_query_value(args) then M.update_status("Enter search text"); return end
    command_manager.execute_interactive("FindNext", args)
end

local function do_find_prev()
    local args = get_query_args()
    if not has_query_value(args) then M.update_status("Enter search text"); return end
    command_manager.execute_interactive("FindPrevious", args)
end

local function do_select_all()
    local args = get_query_args()
    if not has_query_value(args) then M.update_status("Enter search text"); return end
    command_manager.execute_interactive("SelectAllMatches", args)
end

local function do_replace()
    if not has_replace_text() then return end
    local args = get_query_args()
    args.replace_value = qt.PROPERTIES.GET_TEXT(ws.replace_edit)
    command_manager.execute_interactive("FindReplaceCurrent", args)
end

local function do_replace_all()
    if not has_replace_text() then return end
    local args = get_query_args()
    args.replace_value = qt.PROPERTIES.GET_TEXT(ws.replace_edit)
    command_manager.execute_interactive("FindReplaceAll", args)
end

local function do_clear()
    command_manager.execute_interactive("ClearFind", {})
end

-- ============================================================================
-- Create window (once)
-- ============================================================================

local function register_handler(name, fn)
    _G[name] = fn
end

local function create_window()
    local window = qt.WIDGET.CREATE_TOOL_WINDOW()
    qt.WIDGET.SET_WINDOW_FLAGS(window, 0x0000000B)  -- Qt::Tool
    qt.PROPERTIES.SET_TITLE(window, "Find & Filter")
    local ui_constants = require("core.ui_constants")
    qt_set_widget_stylesheet(window, ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR)  -- luacheck: globals qt_set_widget_stylesheet

    -- Restore geometry
    local project_id = db_module.get_current_project_id()
    local saved = project_id and db_module.get_project_setting(project_id, GEOMETRY_KEY)
    if saved and saved.width and saved.width > 100 then
        qt.PROPERTIES.SET_GEOMETRY(window, saved.x, saved.y, saved.width, saved.height)
    else
        qt.PROPERTIES.SET_SIZE(window, 480, 320)
    end

    local content = qt.WIDGET.CREATE()
    local layout = qt.LAYOUT.CREATE_VBOX()
    qt.CONTROL.SET_LAYOUT_SPACING(layout, 4)
    qt.CONTROL.SET_LAYOUT_MARGINS(layout, 10, 10, 10, 10)

    -- Row 1: [Any ▼] [contains ▼] [________search________]
    local row1 = qt.LAYOUT.CREATE_HBOX()
    ws.attr_combo = qt.WIDGET.CREATE_COMBOBOX()
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.attr_combo, "Any")
    local fields = query_engine.get_searchable_fields()
    for _, f in ipairs(fields) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.attr_combo, f.name)
    end
    qt.LAYOUT.ADD_WIDGET(row1, ws.attr_combo)
    ws.op_combo = qt.WIDGET.CREATE_COMBOBOX()
    populate_operators("name")
    qt.LAYOUT.ADD_WIDGET(row1, ws.op_combo)

    register_handler("__find_dlg_attr_changed", function()
        local field = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo)
        populate_operators(field)
        qt.CONTROL.SET_ENABLED(ws.find_edit, not ws.bool_field)
    end)
    qt_set_combobox_change_handler(ws.attr_combo, "__find_dlg_attr_changed")  -- luacheck: globals qt_set_combobox_change_handler
    ws.find_edit = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(ws.find_edit, "search text")
    qt.LAYOUT.ADD_WIDGET(row1, ws.find_edit)
    -- Return in the search field re-executes find from the start (same as
    -- clicking Find), not advance-to-next. This matches macOS Find convention
    -- and recovers when find_state is active with 0 matches.
    register_handler("__find_dlg_edit_return", do_find)
    qt_set_line_edit_return_pressed_handler(ws.find_edit, "__find_dlg_edit_return")
    qt.LAYOUT.ADD_LAYOUT(layout, row1)

    -- Row 2: Replace with  [________replace________]
    local row2 = qt.LAYOUT.CREATE_HBOX()
    ws.replace_label = qt.WIDGET.CREATE_LABEL("Replace with")
    qt.LAYOUT.ADD_WIDGET(row2, ws.replace_label)
    ws.replace_edit = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(ws.replace_edit, "replacement text")
    qt.LAYOUT.ADD_WIDGET(row2, ws.replace_edit)
    qt.LAYOUT.ADD_LAYOUT(layout, row2)

    register_handler("__find_dlg_replace_changed", function()
        local has_text = has_replace_text()
        qt.CONTROL.SET_ENABLED(ws.rep_btn, has_text)
        qt.CONTROL.SET_ENABLED(ws.rep_all_btn, has_text)
    end)
    qt_set_line_edit_text_changed_handler(ws.replace_edit, "__find_dlg_replace_changed")

    -- Row 3: in [All Clips ▼]
    local row3 = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(row3, qt.WIDGET.CREATE_LABEL("in"))
    ws.scope_combo = qt.WIDGET.CREATE_COMBOBOX()
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.scope_combo, "All Clips")
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.scope_combo, "Visible (Sifted)")
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.scope_combo, "Selected Clips")
    qt.LAYOUT.ADD_WIDGET(row3, ws.scope_combo)
    qt.LAYOUT.ADD_STRETCH(row3)
    qt.LAYOUT.ADD_LAYOUT(layout, row3)

    local btn_focus = "QPushButton:focus { border: 1px solid #5ac8fa; }"
    local default_btn_style = "QPushButton { background-color: #0a84ff; color: white; "
        .. "border-radius: 4px; padding: 3px 12px; } "
        .. "QPushButton:focus { border: 1px solid #5ac8fa; }"
    local normal_btn_style = "QPushButton { padding: 3px 12px; } " .. btn_focus

    -- Row 5: Find buttons
    local row5 = qt.LAYOUT.CREATE_HBOX()

    local next_btn = qt.WIDGET.CREATE_BUTTON("Next")
    qt.PROPERTIES.SET_STYLE(next_btn, default_btn_style)
    register_handler("__find_dlg_next", do_find_next)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(next_btn, "__find_dlg_next")
    qt.LAYOUT.ADD_WIDGET(row5, next_btn)

    local prev_btn = qt.WIDGET.CREATE_BUTTON("Prev")
    qt.PROPERTIES.SET_STYLE(prev_btn, normal_btn_style)
    register_handler("__find_dlg_prev", do_find_prev)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(prev_btn, "__find_dlg_prev")
    qt.LAYOUT.ADD_WIDGET(row5, prev_btn)

    local all_btn = qt.WIDGET.CREATE_BUTTON("All")
    register_handler("__find_dlg_all", do_select_all)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(all_btn, "__find_dlg_all")
    qt.LAYOUT.ADD_WIDGET(row5, all_btn)

    local clear_btn = qt.WIDGET.CREATE_BUTTON("Clear")
    register_handler("__find_dlg_clear", do_clear)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(clear_btn, "__find_dlg_clear")
    qt.LAYOUT.ADD_WIDGET(row5, clear_btn)

    qt.LAYOUT.ADD_LAYOUT(layout, row5)

    -- Row 6: Replace buttons (active only when replace field has text)
    local row6 = qt.LAYOUT.CREATE_HBOX()

    ws.rep_btn = qt.WIDGET.CREATE_BUTTON("Replace")
    qt.CONTROL.SET_ENABLED(ws.rep_btn, false)
    register_handler("__find_dlg_rep", do_replace)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ws.rep_btn, "__find_dlg_rep")
    qt.LAYOUT.ADD_WIDGET(row6, ws.rep_btn)

    ws.rep_all_btn = qt.WIDGET.CREATE_BUTTON("Replace All")
    qt.CONTROL.SET_ENABLED(ws.rep_all_btn, false)
    register_handler("__find_dlg_rep_all", do_replace_all)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ws.rep_all_btn, "__find_dlg_rep_all")
    qt.LAYOUT.ADD_WIDGET(row6, ws.rep_all_btn)

    qt.LAYOUT.ADD_LAYOUT(layout, row6)

    -- Status bar
    ws.status_label = qt.WIDGET.CREATE_LABEL("")
    qt.LAYOUT.ADD_WIDGET(layout, ws.status_label)

    -- Geometry persistence
    _G["__find_dlg_save_geo"] = save_window_geometry
    if qt.SIGNAL and qt.SIGNAL.SET_GEOMETRY_CHANGE_HANDLER then
        qt.SIGNAL.SET_GEOMETRY_CHANGE_HANDLER(window, "__find_dlg_save_geo")
    end

    qt.LAYOUT.SET_ON_WIDGET(content, layout)
    qt.LAYOUT.SET_CENTRAL_WIDGET(window, content)

    return window
end

-- ============================================================================
-- Restore settings into widgets
-- ============================================================================

local function restore_settings()
    local settings = load_settings()
    if settings.last_column and ws.attr_combo then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(ws.attr_combo, settings.last_column)
    end
    if settings.last_operator and ws.op_combo then
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT(ws.op_combo, settings.last_operator)
    end
    if settings.last_value and ws.find_edit then
        qt.PROPERTIES.SET_TEXT(ws.find_edit, settings.last_value)
    end
    if settings.last_replace and ws.replace_edit then
        qt.PROPERTIES.SET_TEXT(ws.replace_edit, settings.last_replace)
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Show the unified Find & Filter panel.
function M.show()
    log.event("find_dialog.show")
    if not ws.window then
        log.event("find_dialog.show: creating window")
        ws.window = create_window()
        restore_settings()
    end

    ws.visible = true
    qt.DISPLAY.SHOW(ws.window)
    qt.DISPLAY.RAISE(ws.window)
    qt.DISPLAY.ACTIVATE(ws.window)

    if ws.find_edit then
        qt_set_focus(ws.find_edit)  -- luacheck: globals qt_set_focus
        qt_line_edit_select_all(ws.find_edit)  -- luacheck: globals qt_line_edit_select_all
    end

    qt_create_single_shot_timer(50, function()
        ws.geometry_ready = true
    end)
end

--- Hide the panel.
function M.hide()
    ws.visible = false
    if ws.window and qt.DISPLAY and qt.DISPLAY.SET_VISIBLE then
        qt.DISPLAY.SET_VISIBLE(ws.window, false)
    end
end

--- Get current query from the dialog's text fields.
--- Used by find_clips.lua to re-execute find on content/focus changes.
function M.get_current_query()
    if not ws.attr_combo or not ws.op_combo or not ws.find_edit then return nil end
    local args = get_query_args()
    if not ws.bool_field and (not args.value or args.value == "") then return nil end
    return args
end

--- Check if the panel is currently visible.
function M.is_visible()
    return ws.visible == true
end

return M
