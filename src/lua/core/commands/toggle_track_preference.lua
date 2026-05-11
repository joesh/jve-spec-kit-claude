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

local Track = require("models.track")
local log   = require("core.logger").for_area("commands")

-- autoselect (Avid track auto-select / Premiere track targeting): F4
-- per spec §3, distinct from mix `enabled`. AND-gated with patch.enabled
-- at edit time. Per FR-040a, also routed via this non-undoable command.
local ALLOWED = { muted = true, soloed = true, locked = true, enabled = true, autoselect = true }

local SPEC = {
    undoable = false,
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

    local prev_val = track[args.property]
    local new_val
    if args.value == nil then
        new_val = not prev_val  -- toggle: flip current value
    else
        new_val = args.value and true or false
    end
    track[args.property] = new_val
    track:save()

    local db_new = new_val and 1 or 0
    local db_prev = prev_val and 1 or 0

    log.event("ToggleTrackPreference: track=%s %s %s->%s",
        args.track_id, args.property, tostring(db_prev), tostring(db_new))

    local Signals = require("core.signals")
    Signals.emit("track_preference_changed",
        args.track_id, args.property, db_new, db_prev)

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
