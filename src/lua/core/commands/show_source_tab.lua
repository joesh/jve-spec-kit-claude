--- ShowSourceTab — open (or make visible) the SourceTab in the timeline tab strip.
--
-- Reads the source monitor's loaded master sequence and opens a tab for it.
-- If no master is currently loaded the tab opens showing the empty-placeholder
-- state per FR-007b; no error is raised.
--
-- Non-undoable: tab visibility is a UI preference, not a content mutation.
--
-- @file show_source_tab.lua
local M = {}

local Signals = require("core.signals")
local log     = require("core.logger").for_area("commands")

local SPEC = {
    args               = {},
    persisted          = {},
    undoable           = false,
    no_project_context = true,
    skip_clip_snapshot      = true,
    skip_selection_snapshot = true,
}

local function resolve_source_monitor()
    local pm = require("ui.panel_manager")
    assert(pm, "ShowSourceTab: panel_manager not available")
    local monitor = pm.get_sequence_monitor("source_monitor")
    assert(monitor, "ShowSourceTab: source_monitor not registered in panel_manager")
    return monitor
end

local function open_source_tab(master_seq_id)
    local timeline_panel = require("ui.timeline.timeline_panel")
    if master_seq_id and master_seq_id ~= "" then
        timeline_panel.open_tab(master_seq_id)
        local ts = require("ui.timeline.timeline_state")
        ts.switch_to_source_tab(master_seq_id)
    end
    -- No-source case: tab strip placeholder is handled by the UI layer
    -- (timeline_panel renders an empty source tab when displayed_tab_id is nil
    -- and source_tab_visibility_changed fired with true).
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["ShowSourceTab"] = function(_command)
        local monitor = resolve_source_monitor()
        local master_seq_id = monitor:get_loaded_master_seq_id()

        open_source_tab(master_seq_id)

        Signals.emit("source_tab_visibility_changed", true)
        log.event("ShowSourceTab: master_seq_id=%s", tostring(master_seq_id))
        return true
    end

    return {
        executor = command_executors["ShowSourceTab"],
        spec     = SPEC,
    }
end

return M
