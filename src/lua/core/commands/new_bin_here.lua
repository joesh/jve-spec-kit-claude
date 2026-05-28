--- NewBinHere — keyboard/menu adapter for the pure-model NewBin.
--
-- NewBin (core.commands.new_bin) is pure-model: callers must supply
-- `bin_id` (UUID for the new bin). The Cmd+Shift+N keymap binding
-- has no gesture to carry a UUID, so this adapter generates one and
-- dispatches NewBin.
--
-- Resolution policy:
--   - `bin_id` — generated UUID, fresh per press.
--   - `parent_id` — nil (top-level bin). Conservative default matching
--     the user's likely intent — Avid Cmd+Shift+N also creates top-level
--     bins. A future "create-under-selected-bin" enhancement would read
--     the project browser's current selection here.
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

        -- command_manager.execute drops the executor's secondary return on
        -- success; surface success/failure only (matches BladeAtPlayhead).
        local command_manager = require("core.command_manager")
        local new_bin_id = require("uuid").generate()
        local result = command_manager.execute("NewBin", {
            project_id = project_id,
            bin_id     = new_bin_id,
        })
        assert(type(result) == "table" and type(result.success) == "boolean",
            string.format("NewBinHere: command_manager.execute(\"NewBin\") "
                .. "returned malformed result (got %s) — contract violation",
                type(result)))
        if not result.success then
            local msg = result.error_message
            assert(type(msg) == "string" and msg ~= "",
                "NewBinHere: nested NewBin reported success=false but "
                .. "error_message missing — NewBin contract violation")
            return false, msg
        end
        log.event("NewBinHere: created bin %s", new_bin_id:sub(1, 8))
        return true
    end

    return {
        executor = command_executors["NewBinHere"],
        undoer   = nil,
        spec     = SPEC,
    }
end

return M
