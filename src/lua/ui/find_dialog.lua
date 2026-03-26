--- Unified Find & Filter dialog: non-modal floating window.
--
-- Combines Find, Find & Replace, and Sift into one floating panel.
-- Cmd+F opens in Find mode, Cmd+H opens with Replace expanded,
-- Cmd+Shift+F opens with Sift focus.
--
-- Non-modal: stays open while user works. Eventually dockable.
--
-- @file find_dialog.lua

local qt = require("core.qt_constants")
local query_engine = require("core.query_engine")
local find_state = require("core.find_state")
local sift_state = require("core.sift_state")
local command_manager = require("core.command_manager")
local sift_commands_mod = require("core.sift_commands")
local db_module = require("core.database")
local json = require("dkjson")

local M = {}

local SETTINGS_PATH = (os.getenv("HOME") or "") .. "/.jve/find_dialog_settings.json"
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
    -- Replace controls
    rep_btn = nil,
    rep_all_btn = nil,
    skip_btn = nil,
    -- Context
    clips = nil,
    context = nil,       -- "browser" | "timeline"
    project_id = nil,
    on_find = nil,
    on_navigate = nil,
    save_selection = nil,
    on_restore_selection = nil,
    -- State
    replace_visible = false,
    geometry_ready = false,
}

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

local function populate_operators(field_name)
    if not ws.op_combo then return end
    -- Clear existing items (no CLEAR_COMBOBOX binding — recreate is expensive, skip for now)
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

local function update_status(text)
    if ws.status_label then
        qt.PROPERTIES.SET_TEXT(ws.status_label, text)
    end
end

-- ============================================================================
-- Actions
-- ============================================================================

local function do_find()
    if not ws.clips or #ws.clips == 0 then
        update_status("No clips")
        return false
    end

    local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo)
    local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.op_combo)
    local value = qt.PROPERTIES.GET_TEXT(ws.find_edit)
    if not value or value == "" then
        update_status("Enter search text")
        return false
    end

    -- Save selection before first find
    if not find_state.is_active() and ws.save_selection then
        find_state.save_selection(ws.save_selection())
    end

    -- Scope filtering
    local opts = {}
    if ws.scope_combo then
        local scope_text = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.scope_combo)
        if scope_text == "Visible (Sifted)" and sift_state.is_active() then
            local eval = sift_state.evaluate(ws.clips)
            local hidden = {}
            for _, id in ipairs(eval.hidden_ids) do hidden[id] = true end
            opts.hidden_ids = hidden
        end
    end

    find_state.execute(ws.clips, {column = column, operator = operator, value = value}, opts)

    local count = find_state.get_match_count()
    update_status(string.format("%d match%s", count, count == 1 and "" or "es"))

    -- Persist
    save_settings({
        last_column = column,
        last_operator = operator,
        last_value = value,
        last_replace = ws.replace_edit and qt.PROPERTIES.GET_TEXT(ws.replace_edit) or nil,
    })

    -- Navigate to first match
    if ws.on_find and count > 0 then
        ws.on_find({
            match_count = count,
            current_match = find_state.get_current_match(),
        })
    end
    return true
end

local function do_find_next()
    if not find_state.is_active() then return end
    find_state.next()
    local match = find_state.get_current_match()
    local idx = find_state.get_current_index()
    update_status(string.format("Match %d of %d", idx, find_state.get_match_count()))
    if ws.on_navigate and match then
        ws.on_navigate(match, idx)
    end
end

local function do_find_prev()
    if not find_state.is_active() then return end
    find_state.previous()
    local match = find_state.get_current_match()
    local idx = find_state.get_current_index()
    update_status(string.format("Match %d of %d", idx, find_state.get_match_count()))
    if ws.on_navigate and match then
        ws.on_navigate(match, idx)
    end
end

local function do_sift()
    if not ws.clips or #ws.clips == 0 then return end
    local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo)
    local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.op_combo)
    local value = qt.PROPERTIES.GET_TEXT(ws.find_edit)
    if not value or value == "" then return end

    local query = {column = column, operator = operator, value = value}
    sift_commands_mod.sift(ws.clips, query, ws.project_id)
    local eval = sift_state.evaluate(ws.clips)
    update_status(string.format("Sifted: %d visible, %d hidden", #eval.visible_ids, #eval.hidden_ids))
end

local function do_expand_sift()
    if not ws.clips or not sift_state.is_active() then return end
    local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo)
    local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.op_combo)
    local value = qt.PROPERTIES.GET_TEXT(ws.find_edit)
    if not value or value == "" then return end

    local query = {column = column, operator = operator, value = value}
    sift_commands_mod.expand_sift(ws.clips, query, ws.project_id)
    local eval = sift_state.evaluate(ws.clips)
    update_status(string.format("Sifted: %d visible, %d hidden", #eval.visible_ids, #eval.hidden_ids))
end

local function do_narrow_sift()
    if not ws.clips or not sift_state.is_active() then return end
    local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo)
    local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.op_combo)
    local value = qt.PROPERTIES.GET_TEXT(ws.find_edit)
    if not value or value == "" then return end

    local query = {column = column, operator = operator, value = value}
    sift_commands_mod.narrow_sift(ws.clips, query, ws.project_id)
    local eval = sift_state.evaluate(ws.clips)
    update_status(string.format("Sifted: %d visible, %d hidden", #eval.visible_ids, #eval.hidden_ids))
end

local function do_clear_sift()
    sift_commands_mod.clear_sift(ws.project_id)
    update_status("Sift cleared")
end

local function do_replace()
    if not find_state.is_active() then return end
    local current_id = find_state.get_current_match()
    if not current_id then return end
    command_manager.execute("ReplaceClipProperty", {
        clip_id = current_id,
        column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo),
        find_value = qt.PROPERTIES.GET_TEXT(ws.find_edit),
        replace_value = qt.PROPERTIES.GET_TEXT(ws.replace_edit),
        project_id = ws.project_id,
    })
    do_find_next()
end

local function do_replace_all()
    if not find_state.is_active() then
        if not do_find() then return end
    end
    local match_ids = find_state.get_matches()
    if #match_ids == 0 then return end
    command_manager.execute("ReplaceAllClipProperties", {
        clip_ids = match_ids,
        column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo),
        find_value = qt.PROPERTIES.GET_TEXT(ws.find_edit),
        replace_value = qt.PROPERTIES.GET_TEXT(ws.replace_edit),
        project_id = ws.project_id,
    })
    update_status(string.format("Replaced %d", #match_ids))
end

-- ============================================================================
-- Toggle replace section
-- ============================================================================

local function set_replace_enabled(enabled)
    ws.replace_visible = enabled
    if ws.replace_edit then qt.CONTROL.SET_ENABLED(ws.replace_edit, enabled) end
    if ws.replace_label then qt.CONTROL.SET_ENABLED(ws.replace_label, enabled) end
    if ws.rep_btn then qt.CONTROL.SET_ENABLED(ws.rep_btn, enabled) end
    if ws.rep_all_btn then qt.CONTROL.SET_ENABLED(ws.rep_all_btn, enabled) end
    if ws.skip_btn then qt.CONTROL.SET_ENABLED(ws.skip_btn, enabled) end
end

-- ============================================================================
-- Create window (once)
-- ============================================================================

local function register_handler(name, fn)
    _G[name] = fn
end

local function create_window()
    local window = qt.WIDGET.CREATE_MAIN_WINDOW()
    qt.WIDGET.SET_WINDOW_FLAGS(window, 0x0000000B)  -- Qt::Tool
    qt.PROPERTIES.SET_TITLE(window, "Find & Filter")

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

    -- Row 1: Sentence-style search: [Any ▼] [contains ▼] [________]
    local row1 = qt.LAYOUT.CREATE_HBOX()
    ws.attr_combo = qt.WIDGET.CREATE_COMBOBOX()
    qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.attr_combo, "Any")
    local fields = query_engine.get_searchable_fields()
    for _, f in ipairs(fields) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.attr_combo, f.name)
    end
    qt.LAYOUT.ADD_WIDGET(row1, ws.attr_combo)
    ws.op_combo = qt.WIDGET.CREATE_COMBOBOX()
    local ops = populate_operators("name")
    for _, op in ipairs(ops) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.op_combo, op)
    end
    qt.LAYOUT.ADD_WIDGET(row1, ws.op_combo)
    ws.find_edit = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(ws.find_edit, "search text")
    qt.LAYOUT.ADD_WIDGET(row1, ws.find_edit)
    qt.LAYOUT.ADD_LAYOUT(layout, row1)

    -- Row 2: Replace with [________] (disabled by default)
    local row2 = qt.LAYOUT.CREATE_HBOX()
    ws.replace_label = qt.WIDGET.CREATE_LABEL("Replace with")
    qt.LAYOUT.ADD_WIDGET(row2, ws.replace_label)
    ws.replace_edit = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(ws.replace_edit, "replacement text")
    qt.LAYOUT.ADD_WIDGET(row2, ws.replace_edit)
    qt.LAYOUT.ADD_LAYOUT(layout, row2)

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

    -- Row 5: Find buttons
    local row5 = qt.LAYOUT.CREATE_HBOX()

    local find_btn = qt.WIDGET.CREATE_BUTTON("Find")
    register_handler("__find_dlg_find", do_find)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(find_btn, "__find_dlg_find")
    qt.LAYOUT.ADD_WIDGET(row5, find_btn)

    local prev_btn = qt.WIDGET.CREATE_BUTTON("<")
    register_handler("__find_dlg_prev", do_find_prev)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(prev_btn, "__find_dlg_prev")
    qt.LAYOUT.ADD_WIDGET(row5, prev_btn)

    local next_btn = qt.WIDGET.CREATE_BUTTON(">")
    register_handler("__find_dlg_next", do_find_next)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(next_btn, "__find_dlg_next")
    qt.LAYOUT.ADD_WIDGET(row5, next_btn)

    qt.LAYOUT.ADD_SPACING(row5, 12)

    local sift_btn = qt.WIDGET.CREATE_BUTTON("Sift")
    register_handler("__find_dlg_sift", do_sift)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(sift_btn, "__find_dlg_sift")
    qt.LAYOUT.ADD_WIDGET(row5, sift_btn)

    local expand_btn = qt.WIDGET.CREATE_BUTTON("Expand")
    register_handler("__find_dlg_expand", do_expand_sift)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(expand_btn, "__find_dlg_expand")
    qt.LAYOUT.ADD_WIDGET(row5, expand_btn)

    local narrow_btn = qt.WIDGET.CREATE_BUTTON("Narrow")
    register_handler("__find_dlg_narrow", do_narrow_sift)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(narrow_btn, "__find_dlg_narrow")
    qt.LAYOUT.ADD_WIDGET(row5, narrow_btn)

    local clear_btn = qt.WIDGET.CREATE_BUTTON("Clear")
    register_handler("__find_dlg_clear", do_clear_sift)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(clear_btn, "__find_dlg_clear")
    qt.LAYOUT.ADD_WIDGET(row5, clear_btn)

    qt.LAYOUT.ADD_LAYOUT(layout, row5)

    -- Row 6: Replace buttons (disabled by default)
    local row6 = qt.LAYOUT.CREATE_HBOX()

    ws.rep_btn = qt.WIDGET.CREATE_BUTTON("Replace")
    register_handler("__find_dlg_rep", do_replace)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ws.rep_btn, "__find_dlg_rep")
    qt.LAYOUT.ADD_WIDGET(row6, ws.rep_btn)

    ws.rep_all_btn = qt.WIDGET.CREATE_BUTTON("Replace All")
    register_handler("__find_dlg_rep_all", do_replace_all)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ws.rep_all_btn, "__find_dlg_rep_all")
    qt.LAYOUT.ADD_WIDGET(row6, ws.rep_all_btn)

    ws.skip_btn = qt.WIDGET.CREATE_BUTTON("Skip")
    register_handler("__find_dlg_skip", do_find_next)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ws.skip_btn, "__find_dlg_skip")
    qt.LAYOUT.ADD_WIDGET(row6, ws.skip_btn)

    -- Toggle button for replace section
    local toggle_btn = qt.WIDGET.CREATE_BUTTON("Replace ▼")
    register_handler("__find_dlg_toggle", function()
        ws.replace_visible = not ws.replace_visible
        set_replace_enabled(ws.replace_visible)
        qt.PROPERTIES.SET_TEXT(toggle_btn, ws.replace_visible and "Replace ▲" or "Replace ▼")
    end)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(toggle_btn, "__find_dlg_toggle")
    qt.LAYOUT.ADD_WIDGET(row6, toggle_btn)

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

    -- Start with replace disabled
    set_replace_enabled(false)

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
-- @param opts {clips, context, project_id, show_replace, on_find, on_navigate, save_selection, on_restore_selection}
function M.show(opts)
    assert(opts, "find_dialog.show: opts required")

    -- Update context
    ws.clips = opts.clips
    ws.context = opts.context or "browser"
    ws.project_id = opts.project_id
    ws.on_find = opts.on_find
    ws.on_navigate = opts.on_navigate
    ws.save_selection = opts.save_selection
    ws.on_restore_selection = opts.on_restore_selection

    -- Create window on first call
    if not ws.window then
        ws.window = create_window()
        restore_settings()
    end

    -- Show/expand replace section if requested
    if opts.show_replace then
        set_replace_enabled(true)
    end

    -- Show and bring to front
    qt.DISPLAY.SHOW(ws.window)
    qt.DISPLAY.RAISE(ws.window)
    qt.DISPLAY.ACTIVATE(ws.window)

    -- Enable geometry persistence after layout settles
    qt_create_single_shot_timer(50, function()
        ws.geometry_ready = true
    end)
end

--- Hide the panel.
function M.hide()
    if ws.window and qt.DISPLAY and qt.DISPLAY.SET_VISIBLE then
        qt.DISPLAY.SET_VISIBLE(ws.window, false)
    end
end

--- Check if the panel is currently visible.
function M.is_visible()
    return ws.window ~= nil
end

return M
