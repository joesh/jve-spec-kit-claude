-- ShowBugReporterPrivacy — opens the bug-reporter privacy + consent
-- panel (toggle, identity readout, revoke).
--
-- Bound to Cmd+, by default (standard macOS preferences shortcut). Also
-- invoked from report_bug.show_disabled_notice so F12-while-disabled
-- routes straight to the only UI that re-enables it.

local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id  = {},
        sequence_id = {},
    },
}

function M.register(executors, undoers, db)  -- luacheck: no unused args
    local function executor(command)  -- luacheck: no unused args
        local privacy_panel = require("bug_reporter.ui.privacy_panel")
        privacy_panel.show()
        return true
    end
    return { executor = executor, spec = SPEC }
end

return M
