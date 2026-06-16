--- ToggleSourceRecordTab: flip the displayed tab between source and the
--- active record. Non-undoable; pure UI navigation.
---
--- Behavior:
---   displayed = source tab   → switch_to_record_tab(active_sequence_id)
---   displayed = record tab   → switch_to_source_tab(<last-loaded source>)
---     or, when source has no master loaded → show the EMPTY source tab
---     (kind=source, sequence_id=nil, blank body). This is a real source-
---     side tab the user can flip back from — NOT a blanked record timeline
---     that looks like it lost its content. Picking masters[1] as a fallback
---     would fabricate user intent; a blank record body confused users
---     (TSO 2026-05-17). The empty source tab persists across restart.
---
--- @file toggle_source_record_tab.lua
local M = {}

local SPEC = {
    undoable = false,
    mutates_clips = false,
    no_project_context = true,
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
    args = {},
    keyboard = {
        category    = "Transport",
        display_name = "Toggle Source/Record Tab",
        description  = "Flip the displayed timeline tab between the source master and the active record sequence.",
    },
}

function M.register(executors, undoers, db)
    local function move_focus_to_timeline()
        -- ToggleSourceRecordTab is the keyboard handoff to the timeline:
        -- whichever side ends up showing, subsequent Space/J/K/L/marks
        -- must land in the timeline panel. Independent of which
        -- branch ran (record/source/blank).
        local ok_fm, focus_manager = pcall(require, "ui.focus_manager")
        if ok_fm and focus_manager.focus_panel then
            focus_manager.focus_panel("timeline")
        end
    end

    local function executor(_command)
        local timeline_state = require("ui.timeline.timeline_state")
        local kind = timeline_state.get_displayed_tab_kind()

        if kind == "source" then
            local active = timeline_state.get_active_sequence_id()
            if active == nil or active == "" then
                -- No active record to swap to. Blank the body — same as
                -- the "no source loaded" branch below; consistent shape.
                timeline_state.clear()
                move_focus_to_timeline()
                return true
            end
            timeline_state.switch_to_record_tab(active)
            move_focus_to_timeline()
            return true
        end

        -- displayed is record (or nothing) → show the source side. Need a
        -- master to display; use the source engine's currently-loaded
        -- master. When transport hasn't been initialized for a project
        -- (no project open, headless test environment), there's no
        -- source engine to query — blank the body, same as the
        -- no-master branch below.
        local transport = require("core.playback.transport")
        if not transport.is_bootstrapped() then
            timeline_state.show_empty_source_tab()
            move_focus_to_timeline()
            return true
        end
        local src_seq = transport.engine_for_role("source").loaded_sequence_id
        if src_seq == nil or src_seq == "" then
            timeline_state.show_empty_source_tab()
            move_focus_to_timeline()
            return true
        end
        timeline_state.switch_to_source_tab(src_seq)
        move_focus_to_timeline()
        return true
    end

    return {
        ToggleSourceRecordTab = { executor = executor, spec = SPEC },
    }
end

return M
