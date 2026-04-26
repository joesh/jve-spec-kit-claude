--- SetMasterDefaultLayer command (Feature 013, T061).
---
--- Per FR-007 / contracts/commands.md §SetMasterDefaultLayer:
---   Args: { sequence_id, track_id }
---     sequence_id is the master being mutated (rule 2.29).
---   Pre:
---     * sequence_id.kind == 'master'.
---     * track_id is non-NULL (INV-8 forbids NULL when the master has
---       at least one video track; SetMasterDefaultLayer doesn't NULL).
---     * track_id belongs to sequence_id's V tracks.
---   Mutation: sequences.default_video_layer_track_id ← track_id.
---   Undo: prior value.
---   Signal: sequence_content_changed(sequence_id) — every clip
---     referencing this master with master_layer_track_id IS NULL
---     re-resolves to the new layer.
---
--- @file set_master_default_layer.lua

local M = {}

local Sequence = require("models.sequence")
local Track    = require("models.track")
local log      = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "SetMasterDefaultLayer: '%s' is required (rule 2.29)", name))
    return v
end

function M.execute(args)
    assert(type(args) == "table",
        "SetMasterDefaultLayer.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local track_id    = require_string_arg(args, "track_id")

    local seq = Sequence.find(sequence_id)
    assert(seq, string.format(
        "SetMasterDefaultLayer: sequence %s not found", sequence_id))
    assert(seq.kind == "master", string.format(
        "SetMasterDefaultLayer: sequence %s is kind='%s'; this command is "
        .. "valid only on master sequences (rule 2.29 / contract pre).",
        sequence_id, tostring(seq.kind)))

    -- Track sanity: must belong to THIS master AND be a video track.
    local track_seq_id = Track.get_sequence_id(track_id)
    assert(track_seq_id, string.format(
        "SetMasterDefaultLayer: track %s does not exist", track_id))
    assert(track_seq_id == sequence_id, string.format(
        "SetMasterDefaultLayer: track %s belongs to sequence %s, not the "
        .. "master being mutated %s.",
        track_id, track_seq_id, sequence_id))
    local track = Track.load(track_id)
    assert(track, string.format(
        "SetMasterDefaultLayer: Track.load failed for %s", track_id))
    assert(track.track_type == "VIDEO", string.format(
        "SetMasterDefaultLayer: track %s has track_type='%s'; the master "
        .. "default-video-layer must point at a video track.",
        track_id, tostring(track.track_type)))

    local prior_track_id = seq.default_video_layer_track_id
    Sequence.update(sequence_id, { default_video_layer_track_id = track_id })

    log.event("SetMasterDefaultLayer: master=%s %s -> %s",
        sequence_id, tostring(prior_track_id), tostring(track_id))

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)

    return {
        sequence_id    = sequence_id,
        prior_track_id = prior_track_id,
    }
end

function M.undo(capture)
    assert(type(capture) == "table",
        "SetMasterDefaultLayer.undo: capture table required")
    Sequence.update(capture.sequence_id, {
        default_video_layer_track_id = capture.prior_track_id,
    })
    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", capture.sequence_id)
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        track_id    = { required = true },
    },
    persisted = {
        prior_track_id = { kind = "string" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetMasterDefaultLayer"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetMasterDefaultLayer: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        command:set_parameter("prior_track_id", capture_or_err.prior_track_id or "")
        return true
    end

    command_undoers["SetMasterDefaultLayer"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_track_id
        if prior == "" then prior = nil end
        M.undo({ sequence_id = args.sequence_id, prior_track_id = prior })
        return true
    end

    return {
        executor = command_executors["SetMasterDefaultLayer"],
        undoer   = command_undoers["SetMasterDefaultLayer"],
        spec     = SPEC,
    }
end

return M
