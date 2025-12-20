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
        local deleted_states = {}
        local deleted_props = {}
        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load_optional(clip_id, db)
            if clip then
                sequence_id = sequence_id or clip.owner_sequence_id or clip.track_sequence_id
                local state = command_helper.capture_clip_state(clip)
                if state then
                    state.project_id = clip.project_id
                    state.owner_sequence_id = clip.owner_sequence_id or sequence_id
                    state.clip_kind = clip.clip_kind
                    table.insert(deleted_states, state)
                end
                deleted_props[clip_id] = command_helper.snapshot_properties_for_clip(clip_id)

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
        command:set_parameter("deleted_clip_states", deleted_states)
        command:set_parameter("deleted_clip_properties", deleted_props)
        if not sequence_id or sequence_id == "" then
            sequence_id = (timeline_state and timeline_state.get_sequence_id and timeline_state.get_sequence_id()) or nil
            if not sequence_id or sequence_id == "" then
                set_last_error("Cut: missing sequence_id")
                return false
            end
        end
        command_helper.add_delete_mutation(command, sequence_id, clip_ids)

        timeline_state.set_selection({})
        if timeline_state.clear_edge_selection then
            timeline_state.clear_edge_selection()
        end

        print(string.format("✅ Cut removed %d clip(s)", deleted_count))
        return true
    end

    command_undoers["Cut"] = function(command)
        local states = command:get_parameter("deleted_clip_states") or {}
        local props = command:get_parameter("deleted_clip_properties") or {}
        if type(states) ~= "table" then
            return false
        end

        local conn = require("core.database").get_connection()
        for _, state in ipairs(states) do
            local restored = command_helper.restore_clip_state(state)
            if restored then
                if restored.restore_without_occlusion and conn then
                    restored:restore_without_occlusion(conn)
                elseif restored.save and conn then
                    restored:save(conn, { skip_occlusion = true })
                end
                local clip_props = props[state.id] or {}
                if clip_props and #clip_props > 0 then
                    command_helper.insert_properties_for_clip(state.id, clip_props)
                end
            end
        end

        local sequence_id = command:get_parameter("sequence_id") or (timeline_state and timeline_state.get_sequence_id and timeline_state.get_sequence_id())
        command_helper.reload_timeline(sequence_id)
        print("✅ Undo Cut: Restored deleted clips")
        return true
    end

    return {
        executor = command_executors["Cut"],
        undoer = command_undoers["Cut"]
    }
end

return M
