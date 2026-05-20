--- ToggleTrimMode command: flip the narrow live-bound retrim mode between
--- "overwrite" and "ripple" (spec 019 FR-011).
---
--- Non-undoable — this is UI / process state, not edit history.
--- Reads + writes through `core/edit_mode`, which asserts on bad values
--- (FR-009) and emits `trim_mode_changed` on every flip.
---
--- @file toggle_trim_mode.lua

local M = {}

local SPEC = {
    undoable = false,
    args     = {},
}

function M.register(executors, _undoers, _db)
    local function executor(_command)
        local edit_mode = require("core.edit_mode")
        local current = edit_mode.get_trim_mode()
        local next_mode = (current == "overwrite") and "ripple" or "overwrite"
        edit_mode.set_trim_mode(next_mode)
        return { success = true }
    end

    executors["ToggleTrimMode"] = executor

    return {
        executor = executor,
        spec     = SPEC,
    }
end

return M
