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
local command_manager = require("core.command_manager")
local db_module = require("core.database")
local json = require("dkjson")
local log = require("core.logger").for_area("ui.find")

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
    log.event("do_find: clips=%d", ws.clips and #ws.clips or 0)
    if not ws.clips or #ws.clips == 0 then
        update_status("No clips")
        return false
    end

    local column = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.attr_combo)
    local operator = qt.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(ws.op_combo)
    local value = qt.PROPERTIES.GET_TEXT(ws.find_edit)
    log.event("do_find: column=%s op=%s value=%s", tostring(column), tostring(operator), tostring(value))
    if not value or value == "" then
        update_status("Enter search text")
        return false
    end

    if not find_state.is_active() and ws.save_selection then
        find_state.save_selection(ws.save_selection())
    end

    find_state.execute(ws.clips, {column = column, operator = operator, value = value})

    local count = find_state.get_match_count()
    local current = find_state.get_current_match()
    log.event("do_find: %d matches, current=%s, active=%s", count, tostring(current), tostring(find_state.is_active()))
    update_status(string.format("%d match%s", count, count == 1 and "" or "es"))

    save_settings({
        last_column = column,
        last_operator = operator,
        last_value = value,
        last_replace = ws.replace_edit and qt.PROPERTIES.GET_TEXT(ws.replace_edit) or nil,
    })

    if ws.on_find and count > 0 then
        log.event("do_find: calling on_find callback")
        ws.on_find({
            match_count = count,
            current_match = current,
        })
    else
        log.event("do_find: no on_find callback or 0 matches (on_find=%s)", tostring(ws.on_find))
    end
    return true
end

local function do_find_next()
    log.event("do_find_next: active=%s count=%d idx=%d",
        tostring(find_state.is_active()), find_state.get_match_count(), find_state.get_current_index())
    -- Auto-execute find on first press, then cycle
    if not find_state.is_active() then
        log.event("do_find_next: no active session, executing find first")
        if not do_find() then return end
        -- do_find already navigates to first match
        return
    end
    find_state.next()
    local match = find_state.get_current_match()
    local idx = find_state.get_current_index()
    log.event("do_find_next: after next idx=%d match=%s", idx, tostring(match))
    update_status(string.format("Match %d of %d", idx, find_state.get_match_count()))
    if ws.on_navigate and match then
        ws.on_navigate(match, idx)
    end
end

local function do_find_prev()
    log.event("do_find_prev: active=%s count=%d idx=%d",
        tostring(find_state.is_active()), find_state.get_match_count(), find_state.get_current_index())
    -- Auto-execute find on first press, then cycle backward
    if not find_state.is_active() then
        log.event("do_find_prev: no active session, executing find first")
        if not do_find() then return end
        return
    end
    find_state.previous()
    local match = find_state.get_current_match()
    local idx = find_state.get_current_index()
    log.event("do_find_prev: after prev idx=%d match=%s", idx, tostring(match))
    update_status(string.format("Match %d of %d", idx, find_state.get_match_count()))
    if ws.on_navigate and match then
        ws.on_navigate(match, idx)
    end
end

local function has_replace_text()
    if not ws.replace_edit then return false end
    local text = qt.PROPERTIES.GET_TEXT(ws.replace_edit)
    return text and text ~= ""
end

local function do_replace()
    log.event("do_replace: has_text=%s active=%s", tostring(has_replace_text()), tostring(find_state.is_active()))
    if not has_replace_text() then return end
    if not find_state.is_active() then return end
    local current_id = find_state.get_current_match()
    if not current_id then return end
    log.event("do_replace: replacing clip %s", current_id)
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
    log.event("do_replace_all: has_text=%s active=%s", tostring(has_replace_text()), tostring(find_state.is_active()))
    if not has_replace_text() then return end
    if not find_state.is_active() then
        if not do_find() then return end
    end
    local match_ids = find_state.get_matches()
    log.event("do_replace_all: %d matches to replace", #match_ids)
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
    local ops = populate_operators("name")
    for _, op in ipairs(ops) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(ws.op_combo, op)
    end
    qt.LAYOUT.ADD_WIDGET(row1, ws.op_combo)
    ws.find_edit = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(ws.find_edit, "search text")
    qt.LAYOUT.ADD_WIDGET(row1, ws.find_edit)
    qt.LAYOUT.ADD_LAYOUT(layout, row1)

    -- Row 2: Replace with  [________replace________]
    -- "Replace with" label aligns with the combos above, edit field aligns with find field
    local row2 = qt.LAYOUT.CREATE_HBOX()
    ws.replace_label = qt.WIDGET.CREATE_LABEL("Replace with")
    qt.LAYOUT.ADD_WIDGET(row2, ws.replace_label)
    ws.replace_edit = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_PLACEHOLDER_TEXT(ws.replace_edit, "replacement text")
    qt.LAYOUT.ADD_WIDGET(row2, ws.replace_edit)
    qt.LAYOUT.ADD_LAYOUT(layout, row2)

    -- Monitor replace field: enable/disable Replace buttons
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

    -- Row 5: Find buttons
    local row5 = qt.LAYOUT.CREATE_HBOX()

    local next_btn = qt.WIDGET.CREATE_BUTTON("Next")
    register_handler("__find_dlg_next", do_find_next)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(next_btn, "__find_dlg_next")
    qt.LAYOUT.ADD_WIDGET(row5, next_btn)

    local prev_btn = qt.WIDGET.CREATE_BUTTON("Prev")
    register_handler("__find_dlg_prev", do_find_prev)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(prev_btn, "__find_dlg_prev")
    qt.LAYOUT.ADD_WIDGET(row5, prev_btn)

    local all_btn = qt.WIDGET.CREATE_BUTTON("All")
    register_handler("__find_dlg_all", function()
        log.event("do_select_all")
        -- Execute find if not active
        if not find_state.is_active() then
            if not do_find() then return end
        end
        -- Select all matches via view
        local match_ids = find_state.get_matches()
        log.event("do_select_all: %d matches to select", #match_ids)
        if #match_ids > 0 and ws.on_select_all then
            ws.on_select_all(match_ids)
        end
        update_status(string.format("Selected %d", #match_ids))
    end)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(all_btn, "__find_dlg_all")
    qt.LAYOUT.ADD_WIDGET(row5, all_btn)

    -- Sift buttons removed — sift will return as a proper browser-only filter UI
    -- with visible criteria chips. See find_dialog_with_sift.lua.bak for the code.

    local clear_btn = qt.WIDGET.CREATE_BUTTON("Clear")
    register_handler("__find_dlg_clear", function()
        log.event("do_clear_find")
        find_state.clear()
        update_status("")
    end)
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

    ws.skip_btn = qt.WIDGET.CREATE_BUTTON("Skip")
    register_handler("__find_dlg_skip", do_find_next)
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ws.skip_btn, "__find_dlg_skip")
    qt.LAYOUT.ADD_WIDGET(row6, ws.skip_btn)

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
-- @param opts {clips, context, project_id, on_find, on_navigate, save_selection, on_restore_selection}
function M.show(opts)
    assert(opts, "find_dialog.show: opts required")
    log.event("find_dialog.show: context=%s clips=%d project=%s on_find=%s on_navigate=%s",
        tostring(opts.context), opts.clips and #opts.clips or 0, tostring(opts.project_id),
        tostring(opts.on_find), tostring(opts.on_navigate))

    -- Update context
    ws.clips = opts.clips
    ws.context = opts.context or "browser"
    ws.project_id = opts.project_id
    ws.on_find = opts.on_find
    ws.on_navigate = opts.on_navigate
    ws.on_select_all = opts.on_select_all
    ws.save_selection = opts.save_selection
    ws.on_restore_selection = opts.on_restore_selection

    -- Create window on first call
    if not ws.window then
        log.event("find_dialog.show: creating window")
        ws.window = create_window()
        restore_settings()
    end

    -- Show and bring to front
    log.event("find_dialog.show: displaying window")
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

--- Update the clip list (called when focus changes views).
function M.update_clips(clips)
    ws.clips = clips
    log.event("find_dialog.update_clips: %d clips", clips and #clips or 0)
end

--- Check if the panel is currently visible.
function M.is_visible()
    return ws.window ~= nil
end

return M
