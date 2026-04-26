--- Source Viewer: public API for loading master clips into the source monitor.
--
-- Decouples "load a master clip for viewing" from the project browser.
-- Both the browser (double-click) and commands (MatchFrame) use this
-- instead of reaching into panel_manager directly.
--
-- @file source_viewer.lua
local M = {}

--- Load a master sequence into the source monitor.
-- @param master_seq_id string  The master sequence id
-- @param opts table|nil  Options:
--   skip_focus (bool): if true, don't focus the source_monitor panel
function M.load_master_clip(master_seq_id, opts)
    assert(master_seq_id and master_seq_id ~= "",
        "source_viewer.load_master_clip: master_seq_id required")
    opts = opts or {}

    local pm = require("ui.panel_manager")
    local source = pm.get_sequence_monitor("source_monitor")
    assert(source, "source_viewer: source_monitor not registered in panel_manager")
    source:load_sequence(master_seq_id)

    if not opts.skip_focus then
        local focus_manager = require("ui.focus_manager")
        focus_manager.focus_panel("source_monitor")
    end

    return true
end

return M
