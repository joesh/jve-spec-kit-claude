--- SetPatch command (Feature 015, T028).
---
--- Creates or updates a patch (source-track → record-track routing) on a
--- sequence. Patches are routing configuration — NOT on the undo stack.
--- UNIQUE constraint: one patch per (sequence_id, track_type, source_track_index).
---
--- Signal: patch_changed(sequence_id, track_type, source_track_index, change_type)
---   change_type: "created" | "updated" | "deleted"
---
--- @file set_patch.lua

local M = {}

local Patch = require("models.patch")
local log   = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        sequence_id        = { required = true },
        source_track_index = { required = true },
        project_id         = { required = true },
        track_type         = { required = true },  -- "VIDEO" | "AUDIO"
        record_track_index = {},
        enabled            = {},
    },
}

function M.execute(args)
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SetPatch: sequence_id required")
    assert(type(args.source_track_index) == "number",
        "SetPatch: source_track_index must be a number")
    assert(args.source_track_index >= 0, string.format(
        "SetPatch: source_track_index must be >= 0; got %d", args.source_track_index))
    assert(args.track_type == "VIDEO" or args.track_type == "AUDIO",
        "SetPatch: track_type must be 'VIDEO' or 'AUDIO', got: " .. tostring(args.track_type))

    local existing = Patch.find_by_source(args.sequence_id, args.track_type, args.source_track_index)
    local change_type

    if existing then
        if args.record_track_index ~= nil then
            existing.record_track_index = args.record_track_index
        end
        if args.enabled ~= nil then
            existing.enabled = args.enabled
        end
        existing:save()
        local enabled_val = existing.enabled
        change_type = (enabled_val == false or enabled_val == 0) and "deleted" or "updated"
    else
        change_type = "created"
        assert(args.record_track_index ~= nil, string.format(
            "SetPatch: record_track_index required when creating a new patch "
            .. "(sequence=%s type=%s src=%d)",
            args.sequence_id, args.track_type, args.source_track_index))
        local initial_enabled
        if args.enabled ~= nil then
            initial_enabled = args.enabled
        else
            initial_enabled = 1
        end
        local patch = Patch.create(
            args.sequence_id,
            args.track_type,
            args.source_track_index,
            args.record_track_index,
            { enabled = initial_enabled }
        )
        patch:save()
    end

    log.event("SetPatch: seq=%s type=%s src=%d %s",
        args.sequence_id, args.track_type, args.source_track_index, change_type)

    local Signals = require("core.signals")
    Signals.emit("patch_changed",
        args.sequence_id, args.track_type, args.source_track_index, change_type)

    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    -- Canonical command pattern: executor calls M.execute directly. Asserts
    -- propagate to command_manager's xpcall logger (rule 2.32).
    command_executors["SetPatch"] = function(command)
        local args = command:get_all_parameters()
        return M.execute(args)
    end

    return {
        executor = command_executors["SetPatch"],
        spec     = SPEC,
    }
end

return M
