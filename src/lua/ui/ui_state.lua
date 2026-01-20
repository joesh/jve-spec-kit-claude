--- UI State Service - Provides access to main UI components for commands
--
-- Responsibilities:
-- - Store references to main window and core UI panels
-- - Provide getters for commands that need UI access (e.g., showing dialogs)
--
-- Non-goals:
-- - Not for storing transient UI state (use timeline_state for that)
--
-- Invariants:
-- - Must be initialized before commands try to show dialogs
--
-- Size: ~50 LOC
-- Volatility: low
--
-- @file ui_state.lua
local M = {}

local main_window = nil
local project_browser = nil
local timeline_panel = nil

--- Initialize UI state with main window and optional panel references
-- @param window userdata: QMainWindow instance
-- @param opts table: Optional { project_browser = ..., timeline_panel = ... }
function M.init(window, opts)
    assert(window, "ui_state.init requires main_window")
    main_window = window

    opts = opts or {}
    if opts.project_browser then
        project_browser = opts.project_browser
    end
    if opts.timeline_panel then
        timeline_panel = opts.timeline_panel
    end
end

--- Set timeline panel reference (may be initialized later than main window)
function M.set_timeline_panel(panel)
    timeline_panel = panel
end

--- Set project browser reference
function M.set_project_browser(browser)
    project_browser = browser
end

--- Get main window for dialog parenting
-- @return userdata: QMainWindow instance or nil if not initialized
function M.get_main_window()
    return main_window
end

--- Get project browser reference
-- @return table: Project browser module or nil
function M.get_project_browser()
    return project_browser
end

--- Get timeline panel reference
-- @return table: Timeline panel module or nil
function M.get_timeline_panel()
    return timeline_panel
end

return M
