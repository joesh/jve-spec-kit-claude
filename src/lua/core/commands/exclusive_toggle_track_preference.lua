--- ExclusiveToggleTrackPreference command (spec 025 FR-005).
---
--- Option+click on a track-header M/S button: set the clicked track's
--- preference to the toggled state and EVERY OTHER track of the same kind
--- (video tracks one population, audio another) to the OPPOSITE state —
--- "mute everything except this", "solo only this".
---
--- Not undoable (consistent with the plain ToggleTrackPreference, spec
--- 015 FR-040a). Writes route through core.track_preference (the single
--- preference write chokepoint).
---
--- A locked clicked track is a graceful no-op (FR-005): nothing changes.

local M = {}

local Track             = require("models.track")
local track_preference  = require("core.track_preference")

-- Exclusive toggling is a monitoring gesture — mute/solo only.
local EXCLUSIVE_PROPS = { muted = true, soloed = true }

local SPEC = {
    undoable = false,
    keyboard = {
        category     = "Timeline ▸ Track Header",
        display_name = "Exclusive Toggle Track Preference",
        description  = "Option+click M/S: set this track and the opposite state on "
            .. "all other tracks of the same kind. Bind with property=muted|soloed.",
    },
    args = {
        track_id    = { required = true },
        property    = { required = true },
        project_id  = { required = true },
        sequence_id = { required = true },
    },
}

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "ExclusiveToggleTrackPreference: track_id required")
    assert(EXCLUSIVE_PROPS[args.property], string.format(
        "ExclusiveToggleTrackPreference: property must be muted or soloed; got %s",
        tostring(args.property)))
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "ExclusiveToggleTrackPreference: project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "ExclusiveToggleTrackPreference: sequence_id required (to find sibling tracks)")

    local clicked = Track.load(args.track_id)
    assert(clicked, string.format(
        "ExclusiveToggleTrackPreference: track %s not found", tostring(args.track_id)))

    -- Locked clicked track → graceful no-op (FR-005). Touch nothing.
    if clicked.locked then return true end

    local new_state = not clicked[args.property]

    -- The same-kind population: video tracks XOR audio tracks. The clicked
    -- track is in this list; everything else flips to the opposite state.
    local population = Track.find_by_sequence(args.sequence_id, clicked.track_type)
    assert(population and #population > 0, string.format(
        "ExclusiveToggleTrackPreference: no %s tracks in sequence %s",
        tostring(clicked.track_type), tostring(args.sequence_id)))

    for _, track in ipairs(population) do
        local target = (track.id == args.track_id) and new_state or (not new_state)
        track_preference.set(track, args.property, target)
    end

    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["ExclusiveToggleTrackPreference"] = function(command)
        return M.execute(command:get_all_parameters())
    end

    return {
        executor = command_executors["ExclusiveToggleTrackPreference"],
        spec     = SPEC,
    }
end

return M
