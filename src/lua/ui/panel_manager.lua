--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~162 LOC
-- Volatility: unknown
--
-- @file panel_manager.lua
local qt_constants = require("core.qt_constants")

local M = {}

local state = {
    main_splitter = nil,
    top_splitter = nil,
    focus_manager = nil,
    maximized = nil,
}

local PANEL_INDEX = {
    project_browser = 1,
    viewer = 2,
    inspector = 3,
}

local function get_splitter_sizes(splitter)
    if not splitter or not qt_constants or not qt_constants.LAYOUT or not qt_constants.LAYOUT.GET_SPLITTER_SIZES then
        return nil
    end
    local ok, sizes = pcall(qt_constants.LAYOUT.GET_SPLITTER_SIZES, splitter)
    if ok then
        return sizes
    end
    return nil
end

local function set_splitter_sizes(splitter, sizes)
    if splitter and sizes and qt_constants and qt_constants.LAYOUT and qt_constants.LAYOUT.SET_SPLITTER_SIZES then
        qt_constants.LAYOUT.SET_SPLITTER_SIZES(splitter, sizes)
    end
end

local function focused_panel(panel_id)
    if panel_id and panel_id ~= "" then
        return panel_id
    end
    if state.focus_manager and state.focus_manager.get_focused_panel then
        return state.focus_manager.get_focused_panel()
    end
    return nil
end

function M.init(opts)
    opts = opts or {}
    state.main_splitter = opts.main_splitter
    state.top_splitter = opts.top_splitter
    state.focus_manager = opts.focus_manager
    -- Note: Panel highlights auto-refresh via geometry change handlers in focus_manager
end

local function normalize_sizes(sizes, fallback)
    if not sizes or #sizes == 0 then
        return fallback
    end
    return sizes
end

local function maximize_top_panel(panel_id)
    if not state.top_splitter or not state.main_splitter then
        return false, "Splitters not initialized"
    end

    local panel_index = PANEL_INDEX[panel_id]
    if not panel_index then
        return false, string.format("Unknown panel '%s'", tostring(panel_id))
    end

    local main_sizes = get_splitter_sizes(state.main_splitter) or {1, 1}
    local top_sizes = get_splitter_sizes(state.top_splitter) or {1, 1, 1}
    local total_main = 0
    for _, value in ipairs(main_sizes) do
        total_main = total_main + value
    end
    if total_main == 0 then
        total_main = 1
    end

    state.maximized = {
        panel_id = panel_id,
        main_sizes = normalize_sizes(main_sizes, {1, 1}),
        top_sizes = normalize_sizes(top_sizes, {1, 1, 1}),
    }

    -- Hide timeline, show top area only
    set_splitter_sizes(state.main_splitter, {total_main, 0})

    local new_top_sizes = {0, 0, 0}
    new_top_sizes[panel_index] = total_main
    set_splitter_sizes(state.top_splitter, new_top_sizes)
    return true
end

local function maximize_timeline()
    if not state.main_splitter then
        return false, "Main splitter not initialized"
    end

    local main_sizes = get_splitter_sizes(state.main_splitter) or {1, 1}
    local top_sizes = get_splitter_sizes(state.top_splitter) or {1, 1, 1}
    local total_main = 0
    for _, value in ipairs(main_sizes) do
        total_main = total_main + value
    end
    if total_main == 0 then
        total_main = 1
    end

    state.maximized = {
        panel_id = "timeline",
        main_sizes = normalize_sizes(main_sizes, {1, 1}),
        top_sizes = normalize_sizes(top_sizes, {1, 1, 1}),
    }

    set_splitter_sizes(state.main_splitter, {0, total_main})
    return true
end

local function restore_layout()
    if not state.maximized then
        return false
    end

    if state.maximized.main_sizes then
        set_splitter_sizes(state.main_splitter, state.maximized.main_sizes)
    end
    if state.maximized.top_sizes then
        set_splitter_sizes(state.top_splitter, state.maximized.top_sizes)
    end

    state.maximized = nil
    return true
end

function M.is_maximized()
    return state.maximized ~= nil
end

function M.toggle_maximize(panel_id)
    if not state.main_splitter then
        return false, "Panel manager not initialized"
    end

    local target_panel = focused_panel(panel_id)
    if not target_panel then
        return false, "No focused panel"
    end

    if state.maximized then
        if not panel_id or state.maximized.panel_id == target_panel then
            local restored = restore_layout()
            return restored, nil
        end
        restore_layout()
    end

    if target_panel == "timeline" then
        return maximize_timeline()
    else
        return maximize_top_panel(target_panel)
    end
end

function M.toggle_active_panel()
    return M.toggle_maximize(nil)
end

return M
