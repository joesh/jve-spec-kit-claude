--- NewBinHere — keyboard/menu adapter for the pure-model NewBin.
--
-- NewBin (core.commands.new_bin) is pure-model: callers must supply
-- `bin_id` (UUID for the new bin). The Cmd+Shift+N keymap binding
-- has no gesture to carry a UUID, so this adapter generates one and
-- dispatches NewBin.
--
-- Resolution policy:
--   - `bin_id` — generated UUID, fresh per press.
--   - `parent_id` — nil (top-level bin). Future enhancement could
--     read the currently-selected bin from the project browser and
--     create the new bin as its child; for now top-level is the
--     conservative default and matches the user's likely intent
--     (Avid Cmd+Shift+N also creates top-level bins).
--   - `name` — left nil so NewBin's default ("New Bin") applies.
--
-- This adapter is undoable=false: the nested NewBin call owns the
-- single user-visible undo entry, so Cmd+Z deletes the new bin.

local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
    },
}

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["NewBinHere"] = function(command)
        local args = command:get_all_parameters()
        local project_id = args.project_id
        assert(project_id and project_id ~= "",
            "NewBinHere: project_id required (auto-inject failed)")

        local command_manager = require("core.command_manager")
        local new_bin_id = require("uuid").generate()
        local result = command_manager.execute("NewBin", {
            project_id = project_id,
            bin_id     = new_bin_id,
        })
        assert(type(result) == "table", string.format(
            "NewBinHere: nested NewBin returned non-table (%s)", type(result)))
        if result.success == false then
            local msg = result.error_message
            assert(type(msg) == "string" and msg ~= "",
                "NewBinHere: nested NewBin reported success=false but "
                .. "error_message missing — NewBin contract violation")
            return false, msg
        end
        log.event("NewBinHere: created bin %s", new_bin_id:sub(1, 8))
        return true, { bin_id = new_bin_id }
    end

    return {
        executor = command_executors["NewBinHere"],
        undoer   = nil,
        spec     = SPEC,
    }
end

return M
