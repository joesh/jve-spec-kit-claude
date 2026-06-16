--- Panel layout topology — the single source of truth for which panels
--- exist, their stable ids, display titles, splitter membership, and
--- per-panel default size. Both the widget wiring (ui/layout.lua) and the
--- maximize/persistence logic (ui/panel_manager.lua) derive panel position
--- and defaults from here, so no module hardcodes panel positions or sizes
--- independently (the previous PANEL_INDEX-in-panel_manager vs ADD_WIDGET-
--- order-in-layout coupling had no shared source of truth and could silently
--- desync).
---
--- First concrete step toward the docking arc's PanelManager
--- (docs/panel-tab-architecture-arc.md): panels are addressed by identity,
--- not by a numeric index duplicated across files.
---
--- Pure module — no Qt, no state. Safe to require from tests.
--
-- @file panel_layout.lua

local M = {}

-- Top (horizontal) splitter, left → right.
M.TOP_PANELS = {
    { id = "project_browser",  title = "Project Browser",  default_px = 350 },
    { id = "source_monitor",   title = "Source",           default_px = 350 },
    { id = "timeline_monitor", title = "Timeline Monitor", default_px = 350 },
    { id = "inspector",        title = "Inspector",        default_px = 350 },
}

-- Main (vertical) splitter, top → bottom. The top row hosts the four
-- TOP_PANELS above; the timeline occupies the bottom row.
M.MAIN_PANELS = {
    { id = "top_row",  title = "Top Row",  default_px = 450 },
    { id = "timeline", title = "Timeline", default_px = 450 },
}

local function index_of(list, panel_id)
    for i, panel in ipairs(list) do
        if panel.id == panel_id then return i end
    end
    return nil
end

local function default_sizes(list)
    local sizes = {}
    for i, panel in ipairs(list) do sizes[i] = panel.default_px end
    return sizes
end

--- 1-based position of a panel in the top splitter, or nil if unknown.
function M.top_index(panel_id) return index_of(M.TOP_PANELS, panel_id) end

--- 1-based position of a panel in the main splitter, or nil if unknown.
function M.main_index(panel_id) return index_of(M.MAIN_PANELS, panel_id) end

function M.top_count() return #M.TOP_PANELS end
function M.main_count() return #M.MAIN_PANELS end

function M.default_top_sizes() return default_sizes(M.TOP_PANELS) end
function M.default_main_sizes() return default_sizes(M.MAIN_PANELS) end

-- Validate one splitter's size vector against an expected panel count and
-- the minimum visible width. Returns ok, reason.
local function validate_vector(arr, expected_count, min_px, label)
    if type(arr) ~= "table" then
        return false, string.format("%s sizes missing or not a table", label)
    end
    if #arr ~= expected_count then
        return false, string.format("%s sizes have %d entries, expected %d",
            label, #arr, expected_count)
    end
    for _, sz in ipairs(arr) do
        if type(sz) ~= "number" or sz < min_px then
            return false, string.format("%s panel below %dpx minimum", label, min_px)
        end
    end
    return true
end

--- Validate a persisted splitter-sizes record against the topology.
-- A record is usable only when it describes exactly the declared panels
-- (correct counts) and every panel is at least `min_px` wide. Stale records
-- from an earlier panel count (e.g. a pre-fourth-panel 3-entry top vector)
-- fail the count check — there is no migration; callers fall back to
-- defaults. Returns ok, reason.
-- @param sizes table  { top = {px,...}, main = {px,...} }
-- @param min_px number  minimum visible panel width in pixels
function M.validate_sizes(sizes, min_px)
    assert(type(min_px) == "number", "panel_layout.validate_sizes: min_px required")
    if type(sizes) ~= "table" then
        return false, "sizes record is not a table"
    end
    local ok_top, why_top = validate_vector(sizes.top, M.top_count(), min_px, "top")
    if not ok_top then return false, why_top end
    local ok_main, why_main = validate_vector(sizes.main, M.main_count(), min_px, "main")
    if not ok_main then return false, why_main end
    return true
end

return M
