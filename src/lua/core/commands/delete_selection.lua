--- DeleteSelection command: unified delete for timeline and browser.
--
-- Priority: (1) browser delete if browser focused, (2) mark-based lift/extract if marks set,
-- (3) ripple delete if shift+clips selected, (4) batch delete selected clips,
-- (5) ripple delete selected gaps.
-- Named param: ripple=true triggers ripple delete / extract.
--
-- Non-undoable wrapper — delegates to LiftRange/ExtractRange/DeleteClip/RippleDeleteSelection/RippleDelete.
--
-- @file delete_selection.lua
local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        ripple = { kind = "boolean" },
        project_id = {},
        sequence_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local args = command:get_all_parameters()
        local ripple = args.ripple or false

        local focus_manager = require("ui.focus_manager")
        local focused_panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel()

        -- Browser delete
        if focused_panel == "project_browser" then
            local ok, project_browser = pcall(require, "ui.project_browser")
            if ok and project_browser and project_browser.delete_selected_items then
                project_browser.delete_selected_items()
            end
            return true
        end

        -- Timeline delete
        if focused_panel ~= "timeline" then
            return true  -- not in a deletable context
        end

        local timeline_state = require('ui.timeline.timeline_state')
        local command_manager = require("core.command_manager")
        local undo_redo_controller = require("core.undo_redo_controller")
        undo_redo_controller.clear_toggle()

        -- Mark-based lift/extract: when both marks set, operate on mark range
        local mark_in = timeline_state.get_mark_in and timeline_state.get_mark_in()
        local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out()
        if mark_in and mark_out and mark_out > mark_in then
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
            assert(sequence_id, "DeleteSelection: missing sequence_id for mark-based delete")
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
            assert(project_id and project_id ~= "", "DeleteSelection: missing project_id")

            command_manager.begin_undo_group("DeleteMarkRange")

            local cmd_name = ripple and "ExtractRange" or "LiftRange"
            local result = command_manager.execute(cmd_name, {
                project_id = project_id,
                sequence_id = sequence_id,
                mark_in = mark_in,
                mark_out = mark_out,
            })
            if not result.success then
                log.error("DeleteSelection: %s failed: %s", cmd_name, result.error_message or "unknown")
            else
                command_manager.execute("ClearMarks", {
                    project_id = project_id, sequence_id = sequence_id,
                })
            end

            command_manager.end_undo_group()
            return true
        end

        local selected_clips = timeline_state.get_selected_clips()

        -- Ripple delete selected clips
        if ripple and selected_clips and #selected_clips > 0 then
            local clip_ids = {}
            for _, clip in ipairs(selected_clips) do
                if type(clip) == "table" then
                    clip_ids[#clip_ids + 1] = clip.id or clip.clip_id
                elseif type(clip) == "string" then
                    clip_ids[#clip_ids + 1] = clip
                end
            end

            if #clip_ids > 0 then
                local params = {clip_ids = clip_ids}
                if timeline_state.get_sequence_id then
                    params.sequence_id = timeline_state.get_sequence_id()
                end
                local result = command_manager.execute("RippleDeleteSelection", params)
                if not result.success then
                    print(string.format("Failed to ripple delete selection: %s", result.error_message or "unknown error"))
                end
                return true
            end
        end

        -- Delete selected clips
        if selected_clips and #selected_clips > 0 then
            local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id()
            assert(project_id and project_id ~= "", "DeleteSelection: missing active project_id")

            -- Snapshot IDs before the loop — apply_mutations modifies the
            -- live selected_clips array as each child deletes.
            local clip_ids_to_delete = {}
            for _, clip in ipairs(selected_clips) do
                clip_ids_to_delete[#clip_ids_to_delete + 1] = clip.id
            end

            -- Group all DeleteClip children into one undo atom
            command_manager.begin_undo_group("DeleteSelection")

            local deleted = 0
            local failed = 0
            for _, clip_id in ipairs(clip_ids_to_delete) do
                local result = command_manager.execute("DeleteClip", {
                    clip_id = clip_id,
                    project_id = project_id,
                    sequence_id = active_sequence_id,
                })
                if result.success then
                    deleted = deleted + 1
                else
                    failed = failed + 1
                    log.error("DeleteSelection: DeleteClip failed for %s: %s",
                        clip_id, result.error_message or "unknown")
                end
            end

            command_manager.end_undo_group()

            if deleted > 0 then
                if timeline_state.set_selection then
                    timeline_state.set_selection({})
                end
                log.event("Deleted %d clips (single undo)", deleted)
            end
            if failed > 0 then
                log.warn("DeleteSelection: %d of %d delete(s) failed", failed, deleted + failed)
            end
            return failed == 0 or deleted > 0
        end

        -- Ripple delete selected gaps
        local selected_gaps = timeline_state.get_selected_gaps()
        if #selected_gaps > 0 then
            local gap = selected_gaps[1]
            local params = {
                track_id = gap.track_id,
                gap_start = gap.start_value,
                gap_duration = gap.duration,
            }
            if timeline_state.get_sequence_id then
                params.sequence_id = timeline_state.get_sequence_id()
            end

            local result = command_manager.execute("RippleDelete", params)
            if result.success then
                if timeline_state.clear_gap_selection then
                    timeline_state.clear_gap_selection()
                end
                print(string.format("Ripple deleted gap of %s on track %s", tostring(gap.duration), tostring(gap.track_id)))
            else
                print(string.format("Failed to ripple delete gap: %s", result.error_message or "unknown error"))
            end
            return true
        end

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
