--- UnlinkSelectedClips — keyboard/menu adapter for the pure-model UnlinkClip.
--
-- UnlinkClip (core.commands.link_clips, registered as both "UnlinkClip"
-- and "UnlinkClips" alias) is pure-model: each call removes ONE clip
-- from its link group. The Cmd+Shift+L keymap binding expects to
-- unlink whatever the user has selected — possibly multiple clips
-- spanning multiple groups — so this adapter iterates the selection
-- and dispatches UnlinkClip per clip inside a single undo group so
-- one Cmd+Z reverses the whole batch.
--
-- Resolution policy:
--   - Read the current clip selection via timeline_state.get_selected_clips().
--   - Skip gap clips (they have no link group to leave).
--   - For each surviving selected clip, dispatch UnlinkClip with that
--     clip_id. UnlinkClip is a no-op for clips that aren't linked.
--   - No-op when selection is empty.
--
-- This adapter is undoable=false: the begin_undo_group / end_undo_group
-- pair around the nested UnlinkClip dispatches creates the single
-- user-visible undo entry.
--
-- Parallels LinkSelectedClips and BladeAtPlayhead (see specs/013-…/
-- contracts/commands.md "Cmd+L / Cmd+Shift+L keyboard adapters").

local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
    },
}

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["UnlinkSelectedClips"] = function(command)
        local args = command:get_all_parameters()
        local project_id = args.project_id
        assert(project_id and project_id ~= "",
            "UnlinkSelectedClips: project_id required (auto-inject failed)")

        local timeline_state = require("ui.timeline.timeline_state")
        local selected = timeline_state.get_selected_clips()

        local clip_ids_to_unlink = {}
        for _, sc in ipairs(selected) do
            if not sc.is_gap then
                clip_ids_to_unlink[#clip_ids_to_unlink + 1] = sc.id
            end
        end

        if #clip_ids_to_unlink == 0 then
            log.event("UnlinkSelectedClips: no non-gap selected clips — no-op")
            return true, { unlinked = 0 }
        end

        local command_manager = require("core.command_manager")
        local unlinked = 0
        local group_label = "UnlinkSelectedClips"
        local use_group = #clip_ids_to_unlink > 1
        if use_group then
            command_manager.begin_undo_group(group_label)
        end
        local ok, err = pcall(function()
            for _, clip_id in ipairs(clip_ids_to_unlink) do
                -- Dispatch the registry-aliased name (UnlinkClips, plural)
                -- so the auto-loader resolves the module — UnlinkClip
                -- (singular) is registered as a side-effect of loading
                -- link_clips.lua but has no module_aliases entry.
                local result = command_manager.execute("UnlinkClips", {
                    project_id = project_id,
                    clip_id    = clip_id,
                })
                assert(type(result) == "table", string.format(
                    "UnlinkSelectedClips: nested UnlinkClips returned non-table "
                    .. "for clip %s (%s)", clip_id, type(result)))
                if result.success == false then
                    local msg = result.error_message
                    assert(type(msg) == "string" and msg ~= "",
                        "UnlinkSelectedClips: nested UnlinkClips reported "
                        .. "success=false but error_message missing — "
                        .. "UnlinkClip contract violation")
                    error(string.format(
                        "UnlinkSelectedClips: nested UnlinkClips failed for "
                        .. "clip %s: %s", clip_id, msg), 0)
                end
                unlinked = unlinked + 1
            end
        end)
        if use_group then command_manager.end_undo_group() end
        if not ok then return false, tostring(err) end
        return true, { unlinked = unlinked }
    end

    return {
        executor = command_executors["UnlinkSelectedClips"],
        undoer   = nil,
        spec     = SPEC,
    }
end

return M
