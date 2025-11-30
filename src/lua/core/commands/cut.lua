local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local Clip = require('models.clip')
local command_helper = require("core.command_helper")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["Cut"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing Cut command")
        end

        local selected = timeline_state.get_selected_clips() or {}
        local unique = {}
        local clip_ids = {}

        local function add_clip_id(id)
            if id and id ~= "" and not unique[id] then
                unique[id] = true
                table.insert(clip_ids, id)
            end
        end

        for _, clip in ipairs(selected) do
            if type(clip) == "table" then
                add_clip_id(clip.id or clip.clip_id)
            elseif type(clip) == "string" then
                add_clip_id(clip)
            end
        end

        if #clip_ids == 0 then
            if not dry_run then
                print("Cut: nothing selected")
            end
            return true
        end

        if dry_run then
            return true, { clip_count = #clip_ids }
        end

        local sequence_id = command:get_parameter("sequence_id")
        if (not sequence_id or sequence_id == "") and timeline_state and timeline_state.get_sequence_id then
            sequence_id = timeline_state.get_sequence_id()
        end
        if sequence_id and sequence_id ~= "" then
            command:set_parameter("sequence_id", sequence_id)
        end

        local deleted_count = 0
        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load_optional(clip_id, db)
            if clip then
                sequence_id = sequence_id or clip.owner_sequence_id or clip.track_sequence_id
                if clip:delete(db) then
                    deleted_count = deleted_count + 1
                else
                    print(string.format("WARNING: Cut: failed to delete clip %s", clip_id))
                end
            else
                print(string.format("WARNING: Cut: clip %s not found", clip_id))
            end
        end

        command:set_parameter("cut_clip_ids", clip_ids)
        if not sequence_id or sequence_id == "" then
            sequence_id = (timeline_state and timeline_state.get_sequence_id and timeline_state.get_sequence_id()) or "default_sequence"
        end
        command_helper.add_delete_mutation(command, sequence_id, clip_ids)

        timeline_state.set_selection({})
        if timeline_state.clear_edge_selection then
            timeline_state.clear_edge_selection()
        end

        print(string.format("✅ Cut removed %d clip(s)", deleted_count))
        return true
    end

    -- Undo not implemented in original source? Cut usually mimics delete.
    -- Assuming default undo handling or not implemented yet.

    return {
        executor = command_executors["Cut"]
    }
end

return M
