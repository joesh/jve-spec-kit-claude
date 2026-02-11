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
-- Size: ~102 LOC
-- Volatility: unknown
--
-- @file duplicate_master_clip.lua
local M = {}
local database = require("core.database")
local Clip = require("models.clip")
local command_helper = require("core.command_helper")


local SPEC = {
    args = {
        bin_id = { kind = "string", empty_as_nil = true },
        clip_snapshot = {
            required = true,
            kind = "table",
            fields = {
                media_id = { required = true, kind = "string" },
                fps_numerator = { required = true, kind = "number" },
                fps_denominator = { required = true, kind = "number" },
                start_value = { kind = "number", default = 0 },
                duration_value = { kind = "number" },
                source_in_value = { kind = "number", default = 0 },
                source_out_value = { kind = "number" },
            },
        },
        copied_properties = { kind = "table" },
        name = { kind = "string" },
        new_clip_id = { required = true, kind = "string" },
        project_id = { required = true, kind = "string" },
    }
}
function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DuplicateMasterClip"] = function(command)
        local args = command:get_all_parameters()
        local media_id = args.clip_snapshot.media_id
        local project_id = args.project_id
        local target_bin_id = args.bin_id
        local new_clip_id = args.new_clip_id

        local clip_name = args.name or args.clip_snapshot.name or "Master Clip Copy"

        -- All coordinates are integer frames
        local timeline_start = args.clip_snapshot.start_value or 0
        local source_in_value = args.clip_snapshot.source_in_value or 0
        local source_out_value = args.clip_snapshot.source_out_value
        local duration_value = args.clip_snapshot.duration_value
        if duration_value == nil and source_out_value ~= nil then
            duration_value = source_out_value - source_in_value
        end
        assert(duration_value, "DuplicateMasterClip: missing duration_value (no duration_value and no source_out_value)")

        local clip_opts = {
            id = new_clip_id,
            project_id = project_id,
            clip_kind = "master",
            master_clip_id = args.clip_snapshot.master_clip_id,
            timeline_start = timeline_start,
            duration = duration_value,
            source_in = source_in_value,
            source_out = source_out_value or (source_in_value + duration_value),
            fps_numerator = args.clip_snapshot.fps_numerator,
            fps_denominator = args.clip_snapshot.fps_denominator,
            enabled = args.clip_snapshot.enabled ~= false,
            offline = args.clip_snapshot.offline == true,
        }

        local clip = Clip.create(clip_name, media_id, clip_opts)
        command:set_parameter("project_id", project_id)

        local ok, actions = clip:save({skip_occlusion = true})
        if not ok then
            set_last_error("DuplicateMasterClip: Failed to save duplicated clip")
            return false
        end
        if actions and #actions > 0 then
        end


        if type(args.copied_properties) == "table" and #args.copied_properties > 0 then
            command_helper.delete_properties_for_clip(new_clip_id)
            command_helper.insert_properties_for_clip(new_clip_id, args.copied_properties)
        end

        if target_bin_id and not database.assign_master_clip_to_bin(project_id, new_clip_id, target_bin_id) then
            print(string.format("WARNING: DuplicateMasterClip: Failed to persist bin assignment for %s", new_clip_id))
        end

        print(string.format("✅ Duplicated master clip '%s' → %s", tostring(args.clip_snapshot.name or media_id), new_clip_id))
        return true
    end

    command_undoers["DuplicateMasterClip"] = function(command)
        local args = command:get_all_parameters()
        local clip = Clip.load_optional(args.new_clip_id)
        if clip then
            command_helper.delete_properties_for_clip(args.new_clip_id)
            if not clip:delete() then
                set_last_error("UndoDuplicateMasterClip: Failed to delete duplicated clip")
                return false
            end
        end

        database.assign_master_clip_to_bin(args.project_id, args.new_clip_id, nil)

        return true
    end

    return {
        executor = command_executors["DuplicateMasterClip"],
        undoer = command_undoers["DuplicateMasterClip"],
        spec = SPEC,
    }
end

return M