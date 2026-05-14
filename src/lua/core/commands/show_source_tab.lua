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

-- When the source monitor has nothing loaded (clean startup, or after the
-- user closed the source tab and never reloaded), the menu used to be a
-- silent no-op. Pick the first project master and seed the source monitor;
-- source_viewer.load_master_clip fires source_loaded_changed, which the
-- timeline_panel listener catches and opens the source tab. Pre-existing
-- the auto-open behavior for browser-click; this just supplies the
-- "trigger" event that browser-click would have supplied.
local function seed_first_master_into_source(project_id)
    assert(type(project_id) == "string" and project_id ~= "",
        "ShowSourceTab.seed_first_master_into_source: project_id required")
    local db = require("core.database")
    local masters = db.load_master_clips(project_id)
    if not masters or #masters == 0 then
        log.event("ShowSourceTab: project has no master clips — nothing to show")
        return nil
    end
    local first = masters[1]
    assert(first.clip_id and first.clip_id ~= "",
        "ShowSourceTab: load_master_clips returned a row with no clip_id")
    local source_viewer = require("ui.source_viewer")
    source_viewer.load_master_clip(first.clip_id)
    return first.clip_id
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["ShowSourceTab"] = function(_command)
        local monitor = resolve_source_monitor()
        local master_seq_id = monitor:get_loaded_master_seq_id()

        if not master_seq_id or master_seq_id == "" then
            -- No master loaded → seed one. source_viewer.load_master_clip
            -- emits source_loaded_changed which auto-opens the source tab
            -- via the existing timeline_panel listener. Re-read the monitor
            -- after seeding so we propagate the new id below.
            local project_id = require("ui.timeline.timeline_state").get_project_id()
            assert(project_id and project_id ~= "",
                "ShowSourceTab: no active project_id to pick a master from")
            seed_first_master_into_source(project_id)
            master_seq_id = monitor:get_loaded_master_seq_id()
        end

        if master_seq_id and master_seq_id ~= "" then
            open_source_tab(master_seq_id)
        end

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
