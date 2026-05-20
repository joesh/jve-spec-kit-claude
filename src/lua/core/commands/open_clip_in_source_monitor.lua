--- OpenClipInSourceMonitor — load a timeline clip into the source viewer
--- in live-bound mode (spec 019 FR-017).
---
--- Thin dispatcher to `source_viewer.load_clip`. The command exists so
--- the operation is discoverable + rebindable from the keyboard
--- customization dialog, and so the dispatch goes through the same
--- command_manager pipeline as everything else (constitution II).
---
--- @file open_clip_in_source_monitor.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        clip_id     = { required = true, kind = "string" },
        project_id  = { required = true, kind = "string" },
        sequence_id = { required = true, kind = "string" },  -- the clip's OWNER
    },
}

function M.register(executors, _undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        require("ui.source_viewer").load_clip(args.clip_id)
        return { success = true }
    end

    executors["OpenClipInSourceMonitor"] = executor

    return {
        executor = executor,
        spec     = SPEC,
    }
end

return M
