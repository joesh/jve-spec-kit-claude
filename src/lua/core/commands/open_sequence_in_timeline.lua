--- OpenSequenceInTimeline — load a clip-kind sequence into the timeline
--- panel as the active record sequence (spec 019 FR-019).
---
--- Thin dispatcher to `timeline_panel.load_sequence` + focus_panel.
--- Used by the browser router when activating a clip-sequence (regular
--- timeline) entry — Premiere-equivalent "double-click a sequence in the
--- browser to open it for editing".
---
--- @file open_sequence_in_timeline.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        sequence_id = { required = true, kind = "string" },
        project_id  = { required = true, kind = "string" },
    },
}

function M.register(executors, _undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        require("ui.timeline.timeline_panel").load_sequence(args.sequence_id)
        require("ui.focus_manager").focus_panel("timeline")
        return { success = true }
    end

    executors["OpenSequenceInTimeline"] = executor

    return {
        executor = executor,
        spec     = SPEC,
    }
end

return M
