--- SetMasterChannelState command (Feature 013, T062).
---
--- Per FR-006 / FR-007 / contracts/commands.md §SetMasterChannelState:
---   Args: { sequence_id, channel_index, enabled, gain_db }.
---     sequence_id is the master being mutated (rule 2.29).
---   Pre:
---     * sequence_id.kind == 'master'.
---     * channel_index < master's audio channel count (INV-5).
---     * enabled and gain_db both required (rule 2.13).
---   Mutation: UPSERT media_refs_channel_state(sequence_id, channel_index)
---     with the new (enabled, default_gain_db).
---   Undo: prior row state, or row-absence sentinel.
---   Signal: sequence_content_changed(sequence_id) — every clip that
---     hasn't overridden this channel re-resolves to the new state.
---
--- @file set_master_channel_state.lua

local M = {}

local Sequence  = require("models.sequence")
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
    local sequence_id = require_string_arg(args, "sequence_id")

    local channel_index = args.channel_index
    assert(type(channel_index) == "number" and channel_index >= 0
        and channel_index == math.floor(channel_index), string.format(
        "SetMasterChannelState: channel_index must be a non-negative integer; "
        .. "got %s", tostring(channel_index)))

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

    local channel_count = Sequence.count_master_audio_channels(sequence_id)
    assert(channel_index < channel_count, string.format(
        "SetMasterChannelState: channel_index %d out of bounds for master %s "
        .. "(has %d audio channels). INV-5.",
        channel_index, sequence_id, channel_count))

    local existing = State.find(sequence_id, channel_index)
    local capture = {
        sequence_id   = sequence_id,
        channel_index = channel_index,
    }
    if existing then
        capture.prior_existed         = true
        capture.prior_enabled         = existing.enabled
        capture.prior_default_gain_db = existing.default_gain_db
        State.update({
            owner_sequence_id = sequence_id,
            channel_index     = channel_index,
            enabled           = enabled,
            default_gain_db   = gain_db,
        })
        log.event("SetMasterChannelState: master=%s ch=%d updated -> "
            .. "enabled=%s gain=%s",
            sequence_id, channel_index, tostring(enabled), tostring(gain_db))
    else
        capture.prior_existed = false
        State.insert({
            owner_sequence_id = sequence_id,
            channel_index     = channel_index,
            enabled           = enabled,
            default_gain_db   = gain_db,
        })
        log.event("SetMasterChannelState: master=%s ch=%d new row -> "
            .. "enabled=%s gain=%s",
            sequence_id, channel_index, tostring(enabled), tostring(gain_db))
    end

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)

    return capture
end

function M.undo(capture)
    assert(type(capture) == "table",
        "SetMasterChannelState.undo: capture table required")
    if capture.prior_existed then
        State.update({
            owner_sequence_id = capture.sequence_id,
            channel_index     = capture.channel_index,
            enabled           = capture.prior_enabled,
            default_gain_db   = capture.prior_default_gain_db,
        })
    else
        State.delete(capture.sequence_id, capture.channel_index)
    end

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", capture.sequence_id)
end

local SPEC = {
    args = {
        sequence_id   = { required = true },
        channel_index = { required = true },
        enabled       = { required = true },
        gain_db       = { required = true },
    },
    persisted = {
        prior_existed         = false,
        prior_enabled         = false,
        prior_default_gain_db = 0.0,
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
        command:set_parameter("prior_enabled", cap.prior_enabled or false)
        command:set_parameter("prior_default_gain_db", cap.prior_default_gain_db or 0.0)
        return true
    end

    command_undoers["SetMasterChannelState"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id           = args.sequence_id,
            channel_index         = args.channel_index,
            prior_existed         = args.prior_existed and true or false,
            prior_enabled         = args.prior_enabled and true or false,
            prior_default_gain_db = args.prior_default_gain_db or 0.0,
        })
        return true
    end

    return {
        executor = command_executors["SetMasterChannelState"],
        undoer   = command_undoers["SetMasterChannelState"],
        spec     = SPEC,
    }
end

return M
