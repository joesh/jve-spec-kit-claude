--- PanMonitorMarkBar — gesture-driven mark bar viewport pan.
---
--- Default binding: Opt + wheel/trackpad horizontal scroll on a
--- SequenceMonitor's mark bar. The mark bar's wheel handler converts
--- the pixel delta to a frame delta and dispatches this command;
--- clamping so the viewport stays inside the clip extent is this
--- command's job. The viewport's duration is preserved (the bar pans,
--- doesn't zoom).
---
--- Non-undoable: panning the visible range is a view-state change, not
--- an edit to the project.
---
--- @file pan_monitor_mark_bar.lua
local M = {}

local SPEC = {
    undoable = false,
    mutates_clips = false,
    no_project_context = true,
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
    args = {
        monitor_view_id = { required = true, kind = "string" },
        delta_frames    = { required = true, kind = "number" },
    },
    keyboard = {
        category     = "Gesture",
        display_name = "Pan Monitor Mark Bar",
        description  = "Shift the monitor mark bar's visible range by a "
                    .. "relative frame delta. Bound by default to Opt + "
                    .. "wheel/trackpad horizontal scroll on the mark bar.",
    },
}

function M.register(executors, undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        local view_id = args.monitor_view_id
        local delta   = args.delta_frames
        assert(type(view_id) == "string" and view_id ~= "",
            "PanMonitorMarkBar: monitor_view_id required (non-empty string)")
        assert(type(delta) == "number",
            "PanMonitorMarkBar: delta_frames required (number)")

        local sm = require("ui.panel_manager").get_sequence_monitor(view_id)
        local max_start = sm.total_frames - sm.viewport_duration
        local target = sm.viewport_start + delta
        if target < sm.start_frame then target = sm.start_frame end
        if target > max_start      then target = max_start      end
        sm:set_viewport(target, sm.viewport_duration)
        return true
    end

    return {
        PanMonitorMarkBar = { executor = executor, spec = SPEC },
    }
end

return M
