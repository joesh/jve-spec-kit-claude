--- Test helper: load every per-command module and register its
-- executor/undoer with command_manager. Production code does not need this
-- — command_manager/command_registry auto-load on demand. Tests that need
-- every command available up-front (e.g. ones that exercise undo across
-- many command types) call M.register_commands.
local command_manager = require("core.command_manager")

local M = {}

-- The list of per-command modules under core.commands.
local command_modules = {
    "add_clips_to_sequence", "add_track", "batch_ripple_edit",
    "create_project", "create_sequence", "cut", "delete_bin", "delete_clip",
    "delete_master_clip", "delete_sequence", "deselect_all", "duplicate_master_clip",
    "edit_history", "extend_edit", "go_to_end", "go_to_next_edit", "go_to_prev_edit", "go_to_start",
    "import_fcp7_xml", "import_media", "import_resolve_project", "insert",
    "link_clips", "load_project", "match_frame",
    "move_clip_to_track", "move_to_bin", "new_bin", "nudge", "nudge_selection", "overwrite",
    "relink_clips", "rename_item", "ripple_delete", "ripple_delete_selection",
    "show_keyboard_customization", "show_relink_dialog",
    "select_all", "select_browser_items", "select_clips", "set_clip_property", "set_project_setting",
    "set_sequence_metadata", "set_track_heights", "set_track_property", "setup_project", "split_clip", "step_frame", "toggle_clip_enabled",
    "toggle_fullscreen_view", "toggle_maximize_panel", "toggle_timecode_focus",
    "trim_head", "trim_tail",
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
        local mod = require("core.commands." .. module_name)
        if type(mod) == "table" and type(mod.register) == "function" then
            local existing = {}
            for k in pairs(executors) do existing[k] = true end
            mod.register(executors, undoers, db, command_manager.set_last_error)
            register_new_entries(executors, undoers, existing)
        end
    end

    return executors, undoers
end

return M
