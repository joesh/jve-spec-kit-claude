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
-- Size: ~34 LOC
-- Volatility: unknown
--
-- @file add_track.lua
local M = {}
local Track = require('models.track')


local SPEC = {
    args = {
        project_id = { required = true },
        sequence_id = { required = true },
        track_type = { required = true, kind = "string", one_of = {"video", "audio"} },
    },
    persisted = {
        track_id = {},
    },
}


function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddTrack"] = function(command)
        local args = command:get_all_parameters()
        print("Executing AddTrack command")




        local track
        if args.track_type == "video" then
            track = Track.create_video("Video Track", args.sequence_id)
        elseif args.track_type == "audio" then
            track = Track.create_audio("Audio Track", args.sequence_id)
        else
            print(string.format("WARNING: AddTrack: Unknown track type: %s", args.track_type))
            return false
        end

        command:set_parameter("track_id", track.id)

        if track:save() then
            print(string.format("Added track with ID: %s", track.id))
            return true
        else
            set_last_error("Failed to save track")
            return false
        end
    end

    return {
        executor = command_executors["AddTrack"],
        spec = SPEC,
    }
end

return M
