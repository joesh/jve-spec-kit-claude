local M = {}
local uuid = require("uuid")
local database = require("core.database")
local Clip = require("models.clip")
local command_helper = require("core.command_helper")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DuplicateMasterClip"] = function(command)
        local snapshot = command:get_parameter("clip_snapshot")
        if type(snapshot) ~= "table" then
            set_last_error("DuplicateMasterClip: Missing clip_snapshot parameter")
            return false
        end

        local media_id = snapshot.media_id
        if not media_id or media_id == "" then
            set_last_error("DuplicateMasterClip: Snapshot missing media_id")
            return false
        end

        local project_id = command:get_parameter("project_id") or snapshot.project_id or "default_project"
        local target_bin_id = command:get_parameter("bin_id")
        if target_bin_id == "" then
            target_bin_id = nil
        end

        local new_clip_id = command:get_parameter("new_clip_id")
        if not new_clip_id or new_clip_id == "" then
            new_clip_id = uuid.generate()
            command:set_parameter("new_clip_id", new_clip_id)
        end

        local clip_name = command:get_parameter("name") or snapshot.name or "Master Clip Copy"
        local duration = snapshot.duration or ((snapshot.source_out or 0) - (snapshot.source_in or 0))
        if duration <= 0 then
            duration = 1
        end

        local clip_opts = {
            id = new_clip_id,
            project_id = project_id,
            clip_kind = "master",
            source_sequence_id = snapshot.source_sequence_id,
            start_value = snapshot.start_value or 0,
            duration = duration,
            source_in = snapshot.source_in or 0,
            source_out = snapshot.source_out or ((snapshot.source_in or 0) + duration),
            enabled = snapshot.enabled ~= false,
            offline = snapshot.offline == true,
        }

        local clip = Clip.create(clip_name, media_id, clip_opts)
        command:set_parameter("project_id", project_id)

        local ok, actions = clip:save(db, {skip_occlusion = true})
        if not ok then
            set_last_error("DuplicateMasterClip: Failed to save duplicated clip")
            return false
        end
        if actions and #actions > 0 then
            command:set_parameter("occlusion_actions", actions)
        end

        local copied_properties = command:get_parameter("copied_properties")
        if type(copied_properties) == "table" and #copied_properties > 0 then
            command_helper.delete_properties_for_clip(new_clip_id)
            command_helper.insert_properties_for_clip(new_clip_id, copied_properties)
        end

        if target_bin_id and not database.assign_master_clip_to_bin(project_id, new_clip_id, target_bin_id) then
            print(string.format("WARNING: DuplicateMasterClip: Failed to persist bin assignment for %s", new_clip_id))
        end

        print(string.format("✅ Duplicated master clip '%s' → %s", tostring(snapshot.name or media_id), new_clip_id))
        return true
    end

    command_undoers["DuplicateMasterClip"] = function(command)
        local clip_id = command:get_parameter("new_clip_id")
        if not clip_id or clip_id == "" then
            set_last_error("UndoDuplicateMasterClip: Missing new_clip_id")
            return false
        end

        local project_id = command:get_parameter("project_id") or "default_project"
        local clip = Clip.load_optional(clip_id, db)
        if clip then
            command_helper.delete_properties_for_clip(clip_id)
            if not clip:delete(db) then
                set_last_error("UndoDuplicateMasterClip: Failed to delete duplicated clip")
                return false
            end
        end

        database.assign_master_clip_to_bin(project_id, clip_id, nil)

        return true
    end

    return {
        executor = command_executors["DuplicateMasterClip"],
        undoer = command_undoers["DuplicateMasterClip"],
    }
end

return M
