--- ClearClipOverride command (Feature 013, T056).
---
--- Two variants, distinguished by `kind`:
---
---   kind='channel': Args { sequence_id, clip_id, kind='channel',
---     channel_index }. DELETE the clip_channel_override row.
---     Pre: row exists. Refused if absent (rule 2.13 — no silent no-op).
---     Undo: re-INSERT the prior row (enabled, gain_db).
---
---   kind='layer':   Args { sequence_id, clip_id, kind='layer' }.
---     UPDATE clips SET master_layer_track_id = NULL.
---     Pre: master_layer_track_id is non-NULL. Refused if NULL.
---     Undo: restore the prior track_id.
---
--- Both variants emit sequence_content_changed(sequence_id) so the
--- renderer / preview re-resolves to inherited state.
---
--- @file clear_clip_override.lua

local M = {}

local Clip      = require("models.clip")
local Override  = require("models.clip_channel_override")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "ClearClipOverride: '%s' is required (rule 2.29)", name))
    return v
end

local function execute_channel(args)
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")
    local channel_index = args.channel_index
    assert(type(channel_index) == "number" and channel_index >= 0
        and channel_index == math.floor(channel_index), string.format(
        "ClearClipOverride(channel): channel_index must be a non-negative "
        .. "integer; got %s", tostring(channel_index)))

    local clip = Clip.load_v13_row(clip_id)
    assert(clip, string.format(
        "ClearClipOverride(channel): clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "ClearClipOverride(channel): sequence_id mismatch — clip %s "
        .. "owner=%s args=%s (rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))

    local existing = Override.find(clip_id, channel_index)
    assert(existing, string.format(
        "ClearClipOverride(channel): no override exists on clip %s channel %d "
        .. "(rule 2.13 forbids silently making this a no-op)",
        clip_id, channel_index))

    Override.delete(clip_id, channel_index)
    log.event("ClearClipOverride(channel): clip=%s ch=%d (was enabled=%s gain=%s)",
        clip_id, channel_index, tostring(existing.enabled),
        tostring(existing.gain_db))

    return {
        sequence_id    = sequence_id,
        clip_id        = clip_id,
        kind           = "channel",
        channel_index  = channel_index,
        prior_enabled  = existing.enabled,
        prior_gain_db  = existing.gain_db,
    }
end

local function execute_layer(args)
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")

    local clip = Clip.load_v13_row(clip_id)
    assert(clip, string.format(
        "ClearClipOverride(layer): clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "ClearClipOverride(layer): sequence_id mismatch — clip %s "
        .. "owner=%s args=%s (rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))
    assert(clip.master_layer_track_id ~= nil, string.format(
        "ClearClipOverride(layer): clip %s has no layer override "
        .. "(master_layer_track_id is already NULL).",
        clip_id))

    local prior = clip.master_layer_track_id
    Clip.set_master_layer_track_id(clip_id, nil)
    log.event("ClearClipOverride(layer): clip=%s was=%s -> NULL", clip_id, prior)

    return {
        sequence_id    = sequence_id,
        clip_id        = clip_id,
        kind           = "layer",
        prior_track_id = prior,
    }
end

function M.execute(args)
    assert(type(args) == "table", "ClearClipOverride.execute: args table required")
    local kind = args.kind
    if kind == "channel" then
        local capture = execute_channel(args)
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", capture.sequence_id)
        return capture
    elseif kind == "layer" then
        local capture = execute_layer(args)
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", capture.sequence_id)
        return capture
    else
        error(string.format(
            "ClearClipOverride: kind must be 'channel' or 'layer'; got %s",
            tostring(kind)))
    end
end

function M.undo(capture)
    assert(type(capture) == "table",
        "ClearClipOverride.undo: capture table required")
    if capture.kind == "channel" then
        Override.insert({
            clip_id       = capture.clip_id,
            channel_index = capture.channel_index,
            enabled       = capture.prior_enabled,
            gain_db       = capture.prior_gain_db,
        })
    elseif capture.kind == "layer" then
        Clip.set_master_layer_track_id(capture.clip_id, capture.prior_track_id)
    else
        error("ClearClipOverride.undo: unknown kind " .. tostring(capture.kind))
    end

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", capture.sequence_id)
end

local SPEC = {
    args = {
        sequence_id   = { required = true },
        clip_id       = { required = true },
        kind          = { required = true },
        channel_index = {},   -- channel variant only
    },
    persisted = {
        kind             = { kind = "string" },
        channel_index    = { kind = "number" },
        prior_enabled    = { kind = "boolean" },
        prior_gain_db    = { kind = "number" },
        prior_track_id   = { kind = "string" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["ClearClipOverride"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("ClearClipOverride: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("kind", cap.kind)
        if cap.kind == "channel" then
            assert(type(cap.prior_enabled) == "boolean",
                "ClearClipOverride: channel branch missing prior_enabled")
            assert(type(cap.prior_gain_db) == "number",
                "ClearClipOverride: channel branch missing prior_gain_db")
            command:set_parameter("channel_index", cap.channel_index)
            command:set_parameter("prior_enabled", cap.prior_enabled)
            command:set_parameter("prior_gain_db", cap.prior_gain_db)
        else
            -- Layer branch: prior_track_id is nullable (NULL = inherit
            -- nested sequence's default). Persist nil-vs-set distinctly.
            if cap.prior_track_id ~= nil then
                command:set_parameter("prior_track_id", cap.prior_track_id)
            end
        end
        return true
    end

    command_undoers["ClearClipOverride"] = function(command)
        local args = command:get_all_parameters()
        if args.kind == "channel" then
            assert(type(args.prior_enabled) == "boolean",
                "ClearClipOverride.undo: channel branch missing prior_enabled")
            assert(type(args.prior_gain_db) == "number",
                "ClearClipOverride.undo: channel branch missing prior_gain_db")
            M.undo({
                sequence_id   = args.sequence_id,
                clip_id       = args.clip_id,
                kind          = "channel",
                channel_index = args.channel_index,
                prior_enabled = args.prior_enabled,
                prior_gain_db = args.prior_gain_db,
            })
        else
            M.undo({
                sequence_id    = args.sequence_id,
                clip_id        = args.clip_id,
                kind           = "layer",
                prior_track_id = args.prior_track_id,  -- nullable
            })
        end
        return true
    end

    return {
        executor = command_executors["ClearClipOverride"],
        undoer   = command_undoers["ClearClipOverride"],
        spec     = SPEC,
    }
end

return M
