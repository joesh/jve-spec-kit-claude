--- SetPatch command (Feature 015, T028).
---
--- Creates or updates a patch (source-track → record-track routing) on a
--- sequence. Patches are routing configuration — NOT on the undo stack.
--- UNIQUE constraint: one patch per (sequence_id, source_track_index).
---
--- Signal: patch_changed(sequence_id, source_track_index, change_type)
---   change_type: "created" | "updated"
---
--- @file set_patch.lua

local M = {}

local Patch = require("models.patch")
local Track = require("models.track")
local log   = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        sequence_id        = { required = true },
        source_track_index = { required = true },
        project_id         = { required = true },
        record_track_index = {},
        enabled            = {},
        source_track_type  = {},  -- "VIDEO"|"AUDIO"; when provided, cross-type check is enforced
    },
}

local function assert_track_type_match(sequence_id, src_type, rec_idx)
    local dst = Track.find_at(sequence_id, src_type, rec_idx)
    assert(dst, string.format(
        "SetPatch: cross-track-type drag refused — no %s track at index %d "
        .. "in sequence %s; drag an audio source onto an audio record row "
        .. "and a video source onto a video record row",
        src_type, rec_idx, sequence_id))
end

function M.execute(args)
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SetPatch: sequence_id required")
    assert(type(args.source_track_index) == "number",
        "SetPatch: source_track_index must be a number")
    assert(args.source_track_index >= 0, string.format(
        "SetPatch: source_track_index must be >= 0; got %d",
        args.source_track_index))
    if args.source_track_type ~= nil and args.record_track_index ~= nil then
        assert(args.source_track_type == "VIDEO" or args.source_track_type == "AUDIO",
            "SetPatch: source_track_type must be 'VIDEO' or 'AUDIO', got: "
            .. tostring(args.source_track_type))
        assert_track_type_match(args.sequence_id, args.source_track_type, args.record_track_index)
    end

    local existing = Patch.find_by_source(args.sequence_id, args.source_track_index)
    local change_type

    if existing then
        if args.record_track_index ~= nil then
            existing.record_track_index = args.record_track_index
        end
        if args.enabled ~= nil then
            existing.enabled = args.enabled
        end
        existing:save()
        -- enabled=false/0 is a soft-delete: signal "deleted" so listeners
        -- can remove the routing indicator without a separate DeletePatch command.
        local enabled_val = existing.enabled
        change_type = (enabled_val == false or enabled_val == 0) and "deleted" or "updated"
    else
        change_type = "created"
        assert(args.record_track_index ~= nil, string.format(
            "SetPatch: record_track_index required when creating a new patch "
            .. "(sequence=%s src=%d)",
            args.sequence_id, args.source_track_index))
        local patch = Patch.create(
            args.sequence_id,
            args.source_track_index,
            args.record_track_index,
            { enabled = args.enabled }
        )
        patch:save()
    end

    log.event("SetPatch: seq=%s src=%d %s",
        args.sequence_id, args.source_track_index, change_type)

    local Signals = require("core.signals")
    Signals.emit("patch_changed",
        args.sequence_id, args.source_track_index, change_type)

    return true
end

function M.register(command_executors, _command_undoers, _db, set_last_error)
    command_executors["SetPatch"] = function(command)
        local args = command:get_all_parameters()
        local ok, err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetPatch: " .. tostring(err))
            return false
        end
        return true
    end

    return {
        executor = command_executors["SetPatch"],
        spec     = SPEC,
    }
end

return M
