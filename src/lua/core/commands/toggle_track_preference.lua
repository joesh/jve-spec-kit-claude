--- ToggleTrackPreference command (Feature 015, T031).
---
--- Sets a boolean session-monitoring preference (muted/soloed/locked/enabled)
--- on a track. These are NOT mix decisions — they do NOT land on the undo
--- stack (spec FR-040a). Volume/pan belong to SetTrackMixValue.
---
--- Signal: track_preference_changed(track_id, property, new_val, prev_val)
---
--- @file toggle_track_preference.lua

local M = {}

local Track            = require("models.track")
local track_preference = require("core.track_preference")

-- autoselect (Avid track auto-select / Premiere track targeting): F4
-- per spec §3, distinct from mix `enabled`. AND-gated with patch.enabled
-- at edit time. Per FR-040a, also routed via this non-undoable command.
-- The allowed set + the write/signal path live in core.track_preference,
-- the single chokepoint shared with ExclusiveToggleTrackPreference.
local ALLOWED = track_preference.ALLOWED

local SPEC = {
    undoable = false,
    keyboard = {
        category     = "Timeline ▸ Track Header",
        display_name = "Toggle Track Preference",
        description  = "Flip mute, solo, lock, enable, or autoselect on a track. "
            .. "Bind with property=muted|soloed|locked|enabled|autoselect.",
    },
    args = {
        track_id    = { required = true },
        property    = { required = true },
        value       = {},  -- optional: if absent, flips the current value (toggle)
        sequence_id = {},  -- injected by execute_interactive in UI context
        project_id  = { required = true },
    },
}

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "ToggleTrackPreference: track_id required")
    assert(ALLOWED[args.property], string.format(
        "ToggleTrackPreference: property must be muted/soloed/locked/enabled; got %s",
        tostring(args.property)))

    local track = Track.load(args.track_id)
    assert(track, string.format(
        "ToggleTrackPreference: track %s not found", tostring(args.track_id)))

    local new_val
    if args.value == nil then
        new_val = not track[args.property]  -- toggle: flip current value
    else
        new_val = args.value and true or false
    end

    -- Persist + emit through the shared chokepoint (write/signal contract
    -- identical to before: track_preference_changed(track_id, property,
    -- new_int, prev_int)).
    track_preference.set(track, args.property, new_val)

    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    -- Canonical command pattern: executor calls M.execute directly. Asserts
    -- propagate to command_manager's xpcall (line 1007) which logs the
    -- traceback as `[commands] ERROR: Executor failed (X)`. Pinned by
    -- tests/test_015_command_pattern_no_swallowed_asserts.lua.
    command_executors["ToggleTrackPreference"] = function(command)
        local args = command:get_all_parameters()
        return M.execute(args)
    end

    return {
        executor = command_executors["ToggleTrackPreference"],
        spec     = SPEC,
    }
end

return M
