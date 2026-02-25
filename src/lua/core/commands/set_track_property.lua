--- SetTrackProperty — set a single property on a track (muted, soloed, locked, volume, pan)
--
-- Routes track state changes through the command system for undo/redo.
-- Emits track_mix_changed signal for audio-relevant properties.
--
-- @file set_track_property.lua
local M = {}
local Track = require("models.track")
local Signals = require("core.signals")

local VALID_PROPERTIES = {
    muted = "boolean",
    soloed = "boolean",
    locked = "boolean",
    enabled = "boolean",
    volume = "number",
    pan = "number",
}

local AUDIO_MIX_PROPERTIES = {
    muted = true,
    soloed = true,
    volume = true,
    pan = true,
}

local SPEC = {
    args = {
        track_id = { required = true, kind = "string" },
        property = { required = true, kind = "string" },
        value = { required = true },
        project_id = { required = true, kind = "string" },
    },
    persisted = {
        previous_value = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)

    local function apply_property(track_id, property, value)
        local expected_type = VALID_PROPERTIES[property]
        assert(expected_type, string.format(
            "SetTrackProperty: invalid property '%s' (valid: muted, soloed, locked, enabled, volume, pan)",
            tostring(property)))

        local track = Track.load(track_id)
        assert(track, string.format("SetTrackProperty: track %s not found", tostring(track_id)))

        local previous = track[property]

        if expected_type == "boolean" then
            value = value and true or false
            previous = previous and true or false
        elseif expected_type == "number" then
            assert(type(value) == "number", string.format(
                "SetTrackProperty: property '%s' requires number, got %s",
                property, type(value)))
        end

        track[property] = value
        assert(track:save(), string.format(
            "SetTrackProperty: failed to save track %s", tostring(track_id)))

        if AUDIO_MIX_PROPERTIES[property] then
            Signals.emit("track_mix_changed")
        end

        return previous
    end

    command_executors["SetTrackProperty"] = function(command)
        local args = command:get_all_parameters()
        command:set_parameter("__skip_sequence_replay", true)

        local previous = apply_property(args.track_id, args.property, args.value)
        command:set_parameter("previous_value", previous)
        return true
    end

    command_undoers["SetTrackProperty"] = function(command)
        local args = command:get_all_parameters()
        apply_property(args.track_id, args.property, args.previous_value)
        return true
    end

    return {
        executor = command_executors["SetTrackProperty"],
        undoer = command_undoers["SetTrackProperty"],
        spec = SPEC,
    }
end

return M
