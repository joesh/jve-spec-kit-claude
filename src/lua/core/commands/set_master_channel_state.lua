--- SetMasterChannelState command.
---
--- Args: { sequence_id, master_track_id, enabled, gain_db }.
---   sequence_id is the master being mutated (rule 2.29). The track
---   must live on that sequence and be AUDIO.
--- Pre:
---   * sequence_id.kind == 'master'.
---   * master_track_id refers to an AUDIO track on that master.
---   * enabled and gain_db both required (rule 2.13).
--- Mutation: UPSERT media_refs_channel_state(master_track_id) with the
---   new (enabled, default_gain_db).
--- Undo: prior row state, or row-absence sentinel.
--- Signal: sequence_content_changed(sequence_id) — every clip that
---   hasn't overridden this channel re-resolves to the new state.
---
--- @file set_master_channel_state.lua

local M = {}

local Sequence  = require("models.sequence")
local Track     = require("models.track")
local State     = require("models.media_refs_channel_state")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "SetMasterChannelState: '%s' is required (rule 2.29)", name))
    return v
end

function M.execute(args)
    assert(type(args) == "table",
        "SetMasterChannelState.execute: args table required")
    local sequence_id     = require_string_arg(args, "sequence_id")
    local master_track_id = require_string_arg(args, "master_track_id")

    assert(args.enabled ~= nil,
        "SetMasterChannelState: 'enabled' required (rule 2.13 — no default)")
    assert(type(args.gain_db) == "number",
        "SetMasterChannelState: 'gain_db' required as number (rule 2.13)")
    local enabled = args.enabled and true or false
    local gain_db = args.gain_db

    local seq = Sequence.find(sequence_id)
    assert(seq, string.format(
        "SetMasterChannelState: sequence %s not found", sequence_id))
    assert(seq.kind == "master", string.format(
        "SetMasterChannelState: sequence %s is kind='%s'; this command is "
        .. "valid only on master sequences.",
        sequence_id, tostring(seq.kind)))

    local track = Track.load(master_track_id)
    assert(track, string.format(
        "SetMasterChannelState: master_track %s not found", master_track_id))
    assert(track.sequence_id == sequence_id, string.format(
        "SetMasterChannelState: master_track %s belongs to sequence %s, "
        .. "not the targeted master %s",
        master_track_id, tostring(track.sequence_id), sequence_id))
    assert(track.track_type == "AUDIO", string.format(
        "SetMasterChannelState: master_track %s is %s, not AUDIO",
        master_track_id, tostring(track.track_type)))

    local existing = State.find(master_track_id)
    local capture = {
        sequence_id     = sequence_id,
        master_track_id = master_track_id,
    }
    if existing then
        capture.prior_existed         = true
        capture.prior_enabled         = existing.enabled
        capture.prior_default_gain_db = existing.default_gain_db
        State.update({
            master_track_id = master_track_id,
            enabled         = enabled,
            default_gain_db = gain_db,
        })
        log.event("SetMasterChannelState: master=%s track=%s updated -> "
            .. "enabled=%s gain=%s",
            sequence_id, master_track_id, tostring(enabled), tostring(gain_db))
    else
        capture.prior_existed = false
        State.insert({
            master_track_id = master_track_id,
            enabled         = enabled,
            default_gain_db = gain_db,
        })
        log.event("SetMasterChannelState: master=%s track=%s new row -> "
            .. "enabled=%s gain=%s",
            sequence_id, master_track_id, tostring(enabled), tostring(gain_db))
    end

    return capture
end

function M.undo(capture)
    assert(type(capture) == "table",
        "SetMasterChannelState.undo: capture table required")
    if capture.prior_existed then
        State.update({
            master_track_id = capture.master_track_id,
            enabled         = capture.prior_enabled,
            default_gain_db = capture.prior_default_gain_db,
        })
    else
        State.delete(capture.master_track_id)
    end
end

local SPEC = {
    args = {
        sequence_id     = { required = true },
        master_track_id = { required = true },
        enabled         = { required = true },
        gain_db         = { required = true },
    },
    persisted = {
        prior_existed         = { kind = "boolean" },
        prior_enabled         = { kind = "boolean" },
        prior_default_gain_db = { kind = "number" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetMasterChannelState"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetMasterChannelState: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("prior_existed", cap.prior_existed)
        if cap.prior_existed then
            assert(type(cap.prior_enabled) == "boolean",
                "SetMasterChannelState: prior_existed=true but prior_enabled missing/non-boolean")
            assert(type(cap.prior_default_gain_db) == "number",
                "SetMasterChannelState: prior_existed=true but prior_default_gain_db missing/non-number")
            command:set_parameter("prior_enabled", cap.prior_enabled)
            command:set_parameter("prior_default_gain_db", cap.prior_default_gain_db)
        end
        return true
    end

    command_undoers["SetMasterChannelState"] = function(command)
        local args = command:get_all_parameters()
        local prior_existed = args.prior_existed and true or false
        local undo_args = {
            sequence_id     = args.sequence_id,
            master_track_id = args.master_track_id,
            prior_existed   = prior_existed,
        }
        if prior_existed then
            assert(type(args.prior_enabled) == "boolean",
                "SetMasterChannelState.undo: prior_existed=true but prior_enabled missing")
            assert(type(args.prior_default_gain_db) == "number",
                "SetMasterChannelState.undo: prior_existed=true but prior_default_gain_db missing")
            undo_args.prior_enabled         = args.prior_enabled
            undo_args.prior_default_gain_db = args.prior_default_gain_db
        end
        M.undo(undo_args)
        return true
    end

    return {
        executor = command_executors["SetMasterChannelState"],
        undoer   = command_undoers["SetMasterChannelState"],
        spec     = SPEC,
    }
end

return M
