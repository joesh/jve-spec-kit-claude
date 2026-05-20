--- OpenSequenceInSourceMonitor — load any sequence (master or clip kind)
--- into the source viewer in staged mode (spec 019 FR-018).
---
--- Thin dispatcher to `source_viewer.load_sequence`. Used by the browser
--- router when activating a media-sequence entry, and by browser
--- Opt+Return overrides on clip-sequence entries (FR-022).
---
--- @file open_sequence_in_source_monitor.lua
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
        require("ui.source_viewer").load_sequence(args.sequence_id)
        return { success = true }
    end

    executors["OpenSequenceInSourceMonitor"] = executor

    return {
        executor = executor,
        spec     = SPEC,
    }
end

return M
