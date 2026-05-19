--- ShowSourceTab — open (or make visible) the SourceTab in the timeline tab strip.
--
-- Reads the source monitor's loaded master sequence and opens a tab for it.
-- If no master is currently loaded, blanks the timeline body (same blank
-- state as closing the last tab) — picking masters[1] from the DB is
-- fabrication (TSO 2026-05-17: "opens the tab with a random clip loaded").
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
    assert(type(master_seq_id) == "string" and master_seq_id ~= "",
        "ShowSourceTab.open_source_tab: master_seq_id required — caller must "
        .. "have loaded the source monitor first")
    -- Single canonical pointer-update entry point: switch_to_source_tab
    -- emits displayed_tab_changed. The timeline_panel listener does the
    -- timeline-view rebuild (headers + clips + engine + tab widget).
    -- Auto-open (FR-001b) and this menu command share the same path.
    local ts = require("ui.timeline.timeline_state")
    ts.switch_to_source_tab(master_seq_id)
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["ShowSourceTab"] = function(_command)
        local monitor = resolve_source_monitor()
        local master_seq_id = monitor:get_loaded_master_seq_id()

        if master_seq_id and master_seq_id ~= "" then
            open_source_tab(master_seq_id)
            Signals.emit("source_tab_visibility_changed", true)
            log.event("ShowSourceTab: master_seq_id=%s", master_seq_id)
            return true
        end

        -- No master loaded → blank the timeline body, matching the
        -- close-last-tab state (TSO 2026-05-17, user request). Auto-
        -- seeding masters[1] was fabrication; the user chose nothing,
        -- so the editor shows nothing.
        require("ui.timeline.timeline_state").clear()
        log.event("ShowSourceTab: no master loaded — body blanked")
        return true
    end

    return {
        executor = command_executors["ShowSourceTab"],
        spec     = SPEC,
    }
end

return M
