-- ActivateBrowserSelection
--
-- UI command: activate the currently selected item in the project browser.
--
-- Notes:
-- - This is intentionally *not undoable* (selection/viewer focus changes are UI state).
-- - The executor pulls the selected item from the project browser UI state.
-- - Project context is implicit in the UI; outside UI context, project_id is required.

local M = {}

function M.register()
    return {
        command_name = "ActivateBrowserSelection",
        spec = {
            -- Undoability: false = no history entry.
            undoable = false,
            args = {
                -- project_id is only required when not invoked from UI.
                project_id = { required_outside_ui_context = true, type = "uuid" },
                -- sequence_id is auto-injected by execute_ui() when there's an active sequence.
                sequence_id = { required = false, type = "uuid" },
            },
        },
        executor = function(cmd)
            local ok, browser = pcall(require, "ui.project_browser")
            assert(ok and browser and browser.activate_selection,
                "ActivateBrowserSelection: ui.project_browser module not loaded or missing activate_selection function")

            local success, err = browser.activate_selection()
            assert(success, string.format(
                "ActivateBrowserSelection: activate_selection failed: %s",
                tostring(err or "unknown error")
            ))

            return { success = true }
        end,
    }
end

return M
