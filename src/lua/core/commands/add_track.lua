local M = {}
local Track = require('models.track')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddTrack"] = function(command)
        print("Executing AddTrack command")

        local sequence_id = command:get_parameter("sequence_id")
        local track_type = command:get_parameter("track_type")

        if not sequence_id or sequence_id == "" or not track_type or track_type == "" then
            print("WARNING: AddTrack: Missing required parameters")
            return false
        end

        local track
        if track_type == "video" then
            track = Track.create_video("Video Track", sequence_id)
        elseif track_type == "audio" then
            track = Track.create_audio("Audio Track", sequence_id)
        else
            print(string.format("WARNING: AddTrack: Unknown track type: %s", track_type))
            return false
        end

        command:set_parameter("track_id", track.id)

        if track:save(db) then
            print(string.format("Added track with ID: %s", track.id))
            return true
        else
            print("WARNING: Failed to save track")
            return false
        end
    end

    return {
        executor = command_executors["AddTrack"]
    }
end

return M
