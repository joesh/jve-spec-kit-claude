--- ReportBug command - captures and shows bug report dialog
--
-- Responsibilities:
-- - Trigger manual bug capture
-- - Show submission dialog for review
--
-- @file report_bug.lua
local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id = {},  -- auto-injected by menu system
        sequence_id = {}, -- auto-injected by menu system
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local bug_reporter = require("bug_reporter.init")
        local submission_dialog = require("bug_reporter.ui.submission_dialog")

        -- Capture bug report
        local test_path = bug_reporter.capture_manual("User triggered via menu - Manual bug report")

        if test_path then
            log.event("Bug report captured: %s", test_path)
            -- Show submission dialog (non-blocking so user can review)
            local wrapper = submission_dialog.create(test_path)
            if wrapper and wrapper.dialog and qt_show_dialog then
                qt_show_dialog(wrapper.dialog, false)
            end
        else
            log.error("Bug report capture failed")
        end

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
