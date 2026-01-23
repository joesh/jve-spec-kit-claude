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
-- Size: ~39 LOC
-- Volatility: unknown
--
-- @file command_implementations.lua
-- Original intent (unreviewed):
-- Compatibility shim for legacy tests that require the monolithic
-- core.command_implementations module. The real command execution logic
-- now lives in per-command modules under core.commands and is auto-loaded
-- by command_manager/command_registry. We provide a no-op register_commands
-- so callers that expect the old API continue to work without eagerly
-- loading every command module.
local command_manager = require("core.command_manager")

local M = {}

-- Load and register all command modules to maintain compatibility with legacy
-- tests that expect core.command_implementations.register_commands to populate
-- executor/undoer tables.
local command_modules = {
    "add_clip", "add_track", "batch_command", "batch_ripple_edit",
    "create_clip", "create_project", "create_sequence", "cut", "delete_bin", "delete_clip",
    "delete_master_clip", "delete_sequence", "deselect_all", "duplicate_master_clip",
    "edit_history", "go_to_end", "go_to_next_edit", "go_to_prev_edit", "go_to_start",
    "import_fcp7_xml", "import_media", "import_resolve_project", "insert",
    "insert_clip_to_timeline", "link_clips", "load_project", "match_frame",
    "modify_property", "move_clip_to_track", "move_to_bin", "new_bin", "nudge", "overwrite",
    "relink_media", "rename_item", "ripple_delete", "ripple_delete_selection",
    "ripple_edit", "select_all", "set_clip_property", "set_project_setting", "set_property",
    "set_sequence_metadata", "set_track_heights", "setup_project", "split_clip", "toggle_clip_enabled",
    "toggle_maximize_panel",
}

local function register_new_entries(executors, undoers, before_keys)
    for command_type, executor in pairs(executors) do
        if not before_keys[command_type] and type(executor) == "function" then
            command_manager.register_executor(command_type, executor, undoers and undoers[command_type])
        end
    end
end

function M.register_commands(executors, undoers, db)
    executors = executors or {}
    undoers = undoers or {}

    for _, module_name in ipairs(command_modules) do
        local ok, mod = pcall(require, "core.commands." .. module_name)
        if ok and type(mod) == "table" and type(mod.register) == "function" then
            local existing = {}
            for k in pairs(executors) do existing[k] = true end
            local ok_register = pcall(mod.register, executors, undoers, db, command_manager.set_last_error)
            if ok_register then
                register_new_entries(executors, undoers, existing)
            end
        end
    end

    return executors, undoers
end

return M
