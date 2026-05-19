--- ScrubMonitorPlayhead — gesture-driven playhead scrub.
---
--- Default binding: plain wheel/trackpad horizontal scroll on a
--- SequenceMonitor's mark bar. The mark bar's wheel handler converts
--- the pixel delta to a frame delta and dispatches this command;
--- clamping to the clip extent is this command's job.
---
--- Non-undoable: scrubbing is a transient cursor motion, not an edit
--- to the project. Same shape as MovePlayhead.
---
--- @file scrub_monitor_playhead.lua
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
        display_name = "Scrub Monitor Playhead",
        description  = "Move the monitor's playhead by a relative frame "
                    .. "delta. Bound by default to plain wheel/trackpad "
                    .. "horizontal scroll on the monitor mark bar.",
    },
}

function M.register(executors, undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        local view_id = args.monitor_view_id
        local delta   = args.delta_frames
        assert(type(view_id) == "string" and view_id ~= "",
            "ScrubMonitorPlayhead: monitor_view_id required (non-empty string)")
        assert(type(delta) == "number",
            "ScrubMonitorPlayhead: delta_frames required (number)")

        local sm = require("ui.panel_manager").get_sequence_monitor(view_id)
        local target = sm.playhead + delta
        if target < sm.start_frame      then target = sm.start_frame end
        if target > sm.total_frames - 1 then target = sm.total_frames - 1 end
        sm:seek_to_frame(target)
        return true
    end

    return {
        ScrubMonitorPlayhead = { executor = executor, spec = SPEC },
    }
end

return M
