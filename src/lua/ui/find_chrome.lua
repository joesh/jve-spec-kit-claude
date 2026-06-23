-- ui.find_chrome — shared Cmd+F chrome (magnifying-glass title toggle +
-- hideable Search row + dismissal contract). Used by project_browser
-- (multi-match navigation) and inspector (live property filter).
--
-- The module is responsible for:
--   * the title-bar 🔍 toggle button (style + click → toggle)
--   * the search row container (hidden by default, focus-on-show, Esc-dismissable)
--   * a small registry so cancel.lua can dismiss the first visible instance
--
-- The CALLER owns:
--   * where to place title_toggle_btn in its title layout
--   * where to place container in its main vbox
--   * any extra widgets appended to row_layout (prev/next/all buttons etc.)
--   * the on_text_changed / on_return / on_dismiss callbacks
--
-- API:
--   inst = find_chrome.build({
--       placeholder = "Search",
--       panel_name  = "Inspector",     -- shown in the title-button tooltip
--                                       -- ("Find in Inspector  ⌘F")
--       on_dismiss  = function() end,  -- optional; called after the row hides
--   })                                  -- and the input is cleared
--   inst:show() / inst:hide() / inst:toggle() / inst:is_visible()
--
-- Callers attach their own text-changed / return-pressed handlers to
-- inst.search_input — the chrome stays unaware of the search semantics.
--
--   find_chrome.dismiss_first_visible()  -- used by cancel.lua

local qt_constants = require("core.qt_constants")
local ui_constants = require("core.ui_constants")

-- luacheck: globals qt_set_focus qt_line_edit_select_all

local M = {}

-- Registry of live instances (in build order), kept module-private.
-- Append-only — instances are panel-lifetime objects.
local instances = {}

local function color(key)
    local v = ui_constants.COLORS[key]
    assert(v, "find_chrome: ui_constants.COLORS." .. key .. " is required")
    return v
end

local function unique_handler_name(prefix)
    M._handler_seq = (M._handler_seq or 0) + 1
    return string.format("__find_chrome_%s_%d", prefix, M._handler_seq)
end

local function build_tooltip(panel_name)
    local label = panel_name and ("Find in " .. panel_name) or "Find"
    -- pcall: keyboard_shortcut_registry pulls a chain that isn't loaded in
    -- some headless tests. A missing shortcut just trims the suffix.
    local ok, registry = pcall(require, "core.keyboard_shortcut_registry")
    if not (ok and registry and registry.get_command_shortcuts) then return label end
    local shortcuts = registry.get_command_shortcuts("Find")
    if shortcuts and shortcuts[1] and shortcuts[1].string then
        return label .. "  " .. shortcuts[1].string
    end
    return label
end

local function build_title_toggle_btn(on_click_handler, panel_name)
    local btn = qt_constants.WIDGET.CREATE_BUTTON("\xF0\x9F\x94\x8D")  -- 🔍
    qt_constants.PROPERTIES.SET_STYLE(btn, string.format([[
        QPushButton {
            background: transparent;
            border: none;
            color: %s;
            padding: 2px 8px;
            font-size: 13px;
        }
        QPushButton:hover { color: %s; }
    ]], color("TEXT_MUTED"), color("TEXT_PRIMARY")))
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(btn, on_click_handler)
    if qt_constants.PROPERTIES.SET_TOOLTIP then
        qt_constants.PROPERTIES.SET_TOOLTIP(btn, build_tooltip(panel_name))
    end
    return btn
end

local function build_search_row(placeholder)
    local container = qt_constants.WIDGET.CREATE()
    local row = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(row, 6)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(row, 4, 2, 4, 2)

    local input = qt_constants.WIDGET.CREATE_LINE_EDIT("")
    qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT(input, placeholder)
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        qt_constants.GEOMETRY.SET_SIZE_POLICY(input, "Expanding", "Fixed")
    end
    qt_constants.LAYOUT.ADD_WIDGET(row, input)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        qt_constants.LAYOUT.SET_STRETCH_FACTOR(row, input, 1)
    end

    qt_constants.LAYOUT.SET_ON_WIDGET(container, row)
    if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
        qt_constants.DISPLAY.SET_VISIBLE(container, false)
    end
    return container, row, input
end

local function focus_and_select(input)
    if qt_set_focus then pcall(qt_set_focus, input) end
    if qt_line_edit_select_all then pcall(qt_line_edit_select_all, input) end
end

--- Build a find chrome. See module header for the contract.
function M.build(opts)
    opts = opts or {}
    local placeholder = opts.placeholder or "Search"

    local inst = {
        visible    = false,
        on_dismiss = opts.on_dismiss,
    }

    inst.container, inst.row_layout, inst.search_input = build_search_row(placeholder)

    local toggle_h = unique_handler_name("toggle")
    _G[toggle_h] = function() inst:toggle() end
    inst.title_toggle_btn = build_title_toggle_btn(toggle_h, opts.panel_name)

    function inst:is_visible() return self.visible end

    function inst:show()
        if self.visible then
            focus_and_select(self.search_input)
            return
        end
        self.visible = true
        if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
            qt_constants.DISPLAY.SET_VISIBLE(self.container, true)
        end
        focus_and_select(self.search_input)
    end

    function inst:hide()
        if not self.visible then return end
        self.visible = false
        if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
            qt_constants.DISPLAY.SET_VISIBLE(self.container, false)
        end
        if qt_constants.PROPERTIES.SET_TEXT then
            qt_constants.PROPERTIES.SET_TEXT(self.search_input, "")
        end
        -- on_dismiss lets the caller clear derived state (filter_query, find_state).
        if self.on_dismiss then self.on_dismiss() end
    end

    function inst:toggle()
        if self.visible then self:hide() else self:show() end
    end

    table.insert(instances, inst)
    return inst
end

--- Build a standalone title-bar magnifying-glass button — same look + tooltip
--- as find_chrome.build()'s, but without an inline search row. Used by the
--- timeline, whose Find surface is the floating find_dialog rather than an
--- inline row.
---   opts: { panel_name = "Timeline", on_click = function() end }
function M.make_title_toggle_btn(opts)
    assert(opts and type(opts.on_click) == "function",
        "find_chrome.make_title_toggle_btn: opts.on_click required")
    local handler = unique_handler_name("ext_toggle")
    _G[handler] = opts.on_click
    return build_title_toggle_btn(handler, opts.panel_name)
end

--- Dismiss the first currently-visible chrome. Returns true if any was hidden.
function M.dismiss_first_visible()
    for _, inst in ipairs(instances) do
        if inst.visible then
            inst:hide()
            return true
        end
    end
    return false
end

--- True if any chrome is visible.
function M.any_visible()
    for _, inst in ipairs(instances) do
        if inst.visible then return true end
    end
    return false
end

--- Test seam: drop all registered instances so a test can inject its own.
function M._reset_for_test()
    instances = {}
end

--- Test seam: register a fake instance (must expose `visible` field + `:hide()`
--- method, matching the contract dismiss_first_visible iterates).
function M._register_for_test(inst)
    table.insert(instances, inst)
end

return M
