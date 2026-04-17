--- ReportBug command — snapshot DB + recent commands for reproduction.
--
-- @file report_bug.lua
local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id = {},
        sequence_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local bug_capture = require("bug_reporter.bug_capture")
        local capture_dir = bug_capture.capture({
            description = "User triggered via menu",
        })
        log.event("Bug captured: %s", capture_dir)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
