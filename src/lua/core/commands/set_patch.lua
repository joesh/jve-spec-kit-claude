--- SetPatch command (Feature 015, T028).
---
--- Creates or updates a patch (source-track → record-track routing) on a
--- sequence under a specific source shape. Patches are routing
--- configuration — NOT on the undo stack (per F6, spec §6).
--- UNIQUE constraint: one patch per
--- (sequence_id, track_type, source_shape, source_track_index).
---
--- Signal: patch_changed(sequence_id, track_type, source_shape,
---                       source_track_index, change_type)
---   change_type: "created" | "updated" | "disabled"
---   Note: "disabled" sets enabled=0 on the row but does NOT delete it —
---   the src-btn must continue rendering (in dimmed state) so the user
---   can re-enable it. Deletion would hide the btn entirely.
---
--- @file set_patch.lua

local M = {}

local Patch = require("models.patch")
local log   = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    keyboard = {
        category     = "Timeline ▸ Track Header",
        display_name = "Set Source→Record Patch",
        description  = "Enable, disable, or reroute the source→record patch for "
            .. "a track. Routed from the src-id header button.",
    },
    args = {
        sequence_id        = { required = true },
        source_shape       = { required = true },  -- count of source tracks of track_type
        source_track_index = { required = true },
        -- project_id is auto-injected by command_manager; required so the
        -- framework's ambient-context wiring stays mandatory at the SPEC layer.
        project_id         = { required = true },
        track_type         = { required = true },  -- "VIDEO" | "AUDIO"
        record_track_index = {},
        enabled            = {},
    },
}

function M.execute(args)
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SetPatch: sequence_id required")
    assert(type(args.source_shape) == "number" and args.source_shape > 0, string.format(
        "SetPatch: source_shape must be positive number, got %s",
        tostring(args.source_shape)))
    assert(type(args.source_track_index) == "number",
        "SetPatch: source_track_index must be a number")
    assert(args.source_track_index >= 0, string.format(
        "SetPatch: source_track_index must be >= 0; got %d", args.source_track_index))
    assert(args.track_type == "VIDEO" or args.track_type == "AUDIO",
        "SetPatch: track_type must be 'VIDEO' or 'AUDIO', got: " .. tostring(args.track_type))

    local existing = Patch.find_by_source(args.sequence_id, args.track_type,
        args.source_shape, args.source_track_index)
    local change_type

    if existing then
        if args.record_track_index ~= nil then
            existing.record_track_index = args.record_track_index
        end
        if args.enabled ~= nil then
            existing.enabled = args.enabled
        end
        -- save() normalizes existing.enabled to INTEGER 0/1 in place.
        assert(existing:save(), string.format(
            "SetPatch: patch:save() failed (seq=%s type=%s shape=%d src=%d)",
            args.sequence_id, args.track_type,
            args.source_shape, args.source_track_index))
        change_type = existing.enabled == 0 and "disabled" or "updated"
    else
        change_type = "created"
        assert(args.record_track_index ~= nil, string.format(
            "SetPatch: record_track_index required when creating a new patch "
            .. "(sequence=%s type=%s shape=%d src=%d)",
            args.sequence_id, args.track_type,
            args.source_shape, args.source_track_index))
        assert(args.enabled ~= nil, string.format(
            "SetPatch: enabled required when creating a new patch "
            .. "(sequence=%s type=%s shape=%d src=%d) — caller must supply "
            .. "explicit enabled state (1=on, 0=off, true/false also accepted)",
            args.sequence_id, args.track_type,
            args.source_shape, args.source_track_index))
        local patch = Patch.create(
            args.sequence_id,
            args.track_type,
            args.source_shape,
            args.source_track_index,
            args.record_track_index,
            { enabled = args.enabled }
        )
        assert(patch:save(), string.format(
            "SetPatch: new patch:save() failed (seq=%s type=%s shape=%d src=%d)",
            args.sequence_id, args.track_type,
            args.source_shape, args.source_track_index))
    end

    log.event("SetPatch: seq=%s type=%s shape=%d src=%d %s",
        args.sequence_id, args.track_type,
        args.source_shape, args.source_track_index, change_type)

    local Signals = require("core.signals")
    Signals.emit("patch_changed",
        args.sequence_id, args.track_type,
        args.source_shape, args.source_track_index, change_type)

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
