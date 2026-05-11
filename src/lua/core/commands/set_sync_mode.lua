--- SetSyncMode command (Feature 015, T029).
---
--- Sets the sync_mode on a track. Sync-mode is a session-level routing
--- preference (not a mix decision), so this command does NOT land on the
--- undo stack (spec §3 / FR-040).
---
--- Signal: sync_mode_changed(track_id, new_mode, prev_mode)
---
--- @file set_sync_mode.lua

local M = {}

local Track = require("models.track")
local log   = require("core.logger").for_area("commands")

local VALID_MODES = { off = true, ripple = true, cut = true }

local SPEC = {
    undoable = false,
    args = {
        track_id    = { required = true },
        sync_mode   = { required = true },
        sequence_id = {},  -- injected by execute_interactive in UI context
        project_id  = { required = true },
    },
}

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "SetSyncMode: track_id required")
    assert(VALID_MODES[args.sync_mode], string.format(
        "SetSyncMode: sync_mode must be off/ripple/cut; got %s",
        tostring(args.sync_mode)))

    local track = Track.load(args.track_id)
    assert(track, string.format(
        "SetSyncMode: track %s not found", tostring(args.track_id)))

    local prev_mode = track.sync_mode
    if prev_mode == args.sync_mode then return true end

    track.sync_mode = args.sync_mode
    track:save()

    log.event("SetSyncMode: track=%s %s -> %s",
        args.track_id, tostring(prev_mode), args.sync_mode)

    local Signals = require("core.signals")
    Signals.emit("sync_mode_changed", args.track_id, args.sync_mode, prev_mode)

    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    -- Canonical command pattern: executor calls M.execute directly. Asserts
    -- propagate to command_manager's xpcall logger (rule 2.32).
    command_executors["SetSyncMode"] = function(command)
        local args = command:get_all_parameters()
        return M.execute(args)
    end

    return {
        executor = command_executors["SetSyncMode"],
        spec     = SPEC,
    }
end

return M
