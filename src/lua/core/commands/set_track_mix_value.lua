--- SetTrackMixValue command (Feature 015, T030).
---
--- Sets volume or pan on a track. Mix decisions BELONG on the undo stack
--- (unlike session preferences toggled by ToggleTrackPreference).
--- Refuses muted/soloed/locked/enabled — those belong to ToggleTrackPreference.
---
--- Signal: track_mix_changed(track_id, property, new_val, prev_val)
---
--- @file set_track_mix_value.lua

local M = {}

local Track = require("models.track")
local log   = require("core.logger").for_area("commands")

local ALLOWED = { volume = true, pan = true }

local SPEC = {
    args = {
        track_id    = { required = true },
        property    = { required = true },
        value       = { required = true },
        sequence_id = {},  -- injected by execute_interactive in UI context
        project_id  = { required = true },
    },
    persisted = {
        prev_value = { kind = "number" },
        property   = { kind = "string" },
    },
}

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "SetTrackMixValue: track_id required")
    assert(ALLOWED[args.property], string.format(
        "SetTrackMixValue: property must be volume/pan; got %s",
        tostring(args.property)))
    assert(type(args.value) == "number", string.format(
        "SetTrackMixValue: value must be a number; got %s", type(args.value)))

    local track = Track.load(args.track_id)
    assert(track, string.format(
        "SetTrackMixValue: track %s not found", tostring(args.track_id)))

    local prev_val       = track[args.property]
    track[args.property] = args.value
    track:save()

    log.event("SetTrackMixValue: track=%s %s %s->%s",
        args.track_id, args.property, tostring(prev_val), tostring(args.value))

    local Signals = require("core.signals")
    Signals.emit("track_mix_changed",
        args.track_id, args.property, args.value, prev_val)

    return { property = args.property, prev_val = prev_val }
end

function M.undo(capture)
    assert(type(capture) == "table" and capture.track_id,
        "SetTrackMixValue.undo: capture.track_id required")
    assert(ALLOWED[capture.property],
        "SetTrackMixValue.undo: invalid property in capture")
    assert(type(capture.prev_val) == "number",
        "SetTrackMixValue.undo: prev_val must be a number")

    local track = Track.load(capture.track_id)
    assert(track, string.format(
        "SetTrackMixValue.undo: track %s not found", tostring(capture.track_id)))

    local current_val        = track[capture.property]
    track[capture.property]  = capture.prev_val
    track:save()

    local Signals = require("core.signals")
    Signals.emit("track_mix_changed",
        capture.track_id, capture.property, capture.prev_val, current_val)
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    -- Canonical command pattern: executor calls M.execute directly. Asserts
    -- propagate to command_manager's xpcall logger (rule 2.32).
    command_executors["SetTrackMixValue"] = function(command)
        local args = command:get_all_parameters()
        local result = M.execute(args)
        command:set_parameter("property",   result.property)
        command:set_parameter("prev_value", result.prev_val)
        return true
    end

    command_undoers["SetTrackMixValue"] = function(command)
        local args = command:get_all_parameters()
        assert(type(args.prev_value) == "number",
            "SetTrackMixValue.undo: prev_value not persisted on command")
        M.undo({
            track_id  = args.track_id,
            property  = args.property,
            prev_val  = args.prev_value,
        })
        return true
    end

    return {
        executor = command_executors["SetTrackMixValue"],
        undoer   = command_undoers["SetTrackMixValue"],
        spec     = SPEC,
    }
end

return M
