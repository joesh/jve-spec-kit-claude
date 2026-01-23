--- SetTrackHeights command - sets track heights for a sequence
--
-- Responsibilities:
-- - Persist track heights for timeline display
-- - Non-undoable (UI preference, not document state)
-- - Scriptable for automation
--
-- @file set_track_heights.lua
local M = {}
local database = require("core.database")

local SPEC = {
    undoable = false,
    args = {
        sequence_id = { required = true, kind = "string" },
        track_heights = { required = true },  -- table mapping track_id -> height
        project_id = { required = true, kind = "string" },
    },
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SetTrackHeights"] = function(command)
        local args = command:get_all_parameters()
        command:set_parameter("__skip_sequence_replay", true)

        local sequence_id = args.sequence_id
        local track_heights = args.track_heights

        if type(track_heights) ~= "table" then
            set_last_error("SetTrackHeights: track_heights must be a table")
            return false
        end

        local ok = database.set_sequence_track_heights(sequence_id, track_heights)
        if not ok then
            set_last_error("SetTrackHeights: failed to persist track heights")
            return false
        end

        return true
    end

    -- No undoer - this is a non-undoable command

    return {
        executor = command_executors["SetTrackHeights"],
        spec = SPEC,
    }
end

return M
