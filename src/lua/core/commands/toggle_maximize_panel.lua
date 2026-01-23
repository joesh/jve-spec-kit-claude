--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~14 LOC
-- Volatility: unknown
--
-- @file toggle_maximize_panel.lua
-- Original intent (unreviewed):
-- ToggleMaximizePanel command
local M = {}


local SPEC = {
    undoable = false,
    args = {
        panel_id = {},
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(executors, undoers, db)
    
    local function executor(command)
        local args = command:get_all_parameters()
        local panel_manager = require("ui.panel_manager")

        local ok, err = panel_manager.toggle_maximize(args.panel_id)
        if not ok and err then
            print(string.format("WARNING: ToggleMaximizePanel: %s", err))
        end
        return true
    end

    -- No undo needed for UI state changes that are non-recording
    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
