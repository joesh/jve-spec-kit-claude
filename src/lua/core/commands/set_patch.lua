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
local log   = require("core.logger").for_area("commands")

-- Stable 12-hue palette per spec §4. Colors alternate enough that
-- adjacent-index patches are visually distinct even on overflow wrap.
local PATCH_PALETTE = {
    "#e64b3d", "#3d7ee6", "#27ae60", "#f39c12",
    "#9b59b6", "#1abc9c", "#e67e22", "#2980b9",
    "#d35400", "#16a085", "#8e44ad", "#c0392b",
}

local function pick_patch_color(sequence_id)
    local existing = Patch.find_by_sequence(sequence_id)
    local idx = (#existing % #PATCH_PALETTE) + 1
    return PATCH_PALETTE[idx]
end

local SPEC = {
    undoable = false,
    args = {
        sequence_id        = { required = true },
        source_track_index = { required = true },
        project_id         = { required = true },
        record_track_index = {},
        enabled            = {},
        source_track_type  = {},  -- "VIDEO"|"AUDIO"; when provided, cross-type check is enforced
        record_track_type  = {},  -- "VIDEO"|"AUDIO"; required when source_track_type is provided
    },
}

-- Cross-type guard: source and record must be the same track type.
-- VIDEO sources must route to VIDEO record tracks; AUDIO to AUDIO.
-- V1 and A1 share track_index=1, so index alone is ambiguous — both types must be passed.
local function assert_track_type_match(src_type, rec_type, sequence_id, src_idx, rec_idx)
    assert(src_type == rec_type, string.format(
        "SetPatch: cross-track-type routing refused — source is %s (index %d) but "
        .. "record track is %s (index %d) in sequence %s; "
        .. "route audio sources to audio record rows and video to video",
        src_type, src_idx, rec_type, rec_idx, sequence_id))
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
        assert(args.record_track_type ~= nil, string.format(
            "SetPatch: record_track_type required when source_track_type is provided "
            .. "(sequence=%s src=%d rec=%d)",
            args.sequence_id, args.source_track_index, args.record_track_index))
        assert(args.record_track_type == "VIDEO" or args.record_track_type == "AUDIO",
            "SetPatch: record_track_type must be 'VIDEO' or 'AUDIO', got: "
            .. tostring(args.record_track_type))
        assert_track_type_match(args.source_track_type, args.record_track_type,
            args.sequence_id, args.source_track_index, args.record_track_index)
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
        -- New patches start enabled per spec §4 (user just wired a route).
        -- enabled is optional in args; absence means "start enabled."
        local initial_enabled
        if args.enabled ~= nil then
            initial_enabled = args.enabled
        else
            initial_enabled = 1
        end
        local color = pick_patch_color(args.sequence_id)
        local patch = Patch.create(
            args.sequence_id,
            args.source_track_index,
            args.record_track_index,
            { enabled = initial_enabled, color = color }
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
