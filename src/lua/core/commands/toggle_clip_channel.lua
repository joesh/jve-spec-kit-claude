--- ToggleClipChannel command (Feature 013, T054).
---
--- Per FR-014 and contracts/commands.md §ToggleClipChannel:
---   Args: { sequence_id, clip_id, channel_index }
---     sequence_id is the clip's owner_sequence_id (rule 2.29).
---   Pre: clip exists; clip.owner_sequence_id == sequence_id;
---        nested sequence has at least channel_index+1 audio channels.
---   Mutation:
---     - No clip_channel_override row for (clip_id, channel_index):
---       INSERT row with enabled = NOT inherited_enabled,
---       gain_db = inherited_gain_db (rule 2.13: materialize inherited;
---       NEVER let SQL DEFAULT 0 sneak through).
---     - Row exists: UPDATE enabled to its opposite. gain_db untouched.
---   Undo: row's prior state (or row-absence sentinel).
---   Signal: sequence_content_changed(sequence_id).
---
--- First-landing limit: clip.nested_sequence_id must be kind='master'.
--- Multi-level inheritance (clip → nested → master) is deferred — we'd
--- need to walk the chain to find the leaf master that owns the channel
--- state. Refused with a loud message rather than silently picking one.
---
--- @file toggle_clip_channel.lua

local M = {}

local Clip      = require("models.clip")
local Sequence  = require("models.sequence")
local Override  = require("models.clip_channel_override")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "ToggleClipChannel: '%s' is required (rule 2.29)", name))
    return v
end

--- Pure-logic entry point. Returns an undo capture.
---
--- @param args table { sequence_id, clip_id, channel_index }
--- @return table {
---   sequence_id, clip_id, channel_index,
---   prior_existed (bool),
---   prior_enabled (bool, when prior_existed),
---   prior_gain_db (number, when prior_existed),
--- }
function M.execute(args)
    assert(type(args) == "table", "ToggleClipChannel.execute: args table required")
    local sequence_id = require_string_arg(args, "sequence_id")
    local clip_id     = require_string_arg(args, "clip_id")
    local channel_index = args.channel_index
    assert(type(channel_index) == "number" and channel_index >= 0
        and channel_index == math.floor(channel_index), string.format(
        "ToggleClipChannel: channel_index must be a non-negative integer; got %s",
        tostring(channel_index)))

    local clip = Clip.load_v13_row(clip_id)
    assert(clip, string.format(
        "ToggleClipChannel: clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "ToggleClipChannel: sequence_id mismatch — clip %s owner=%s, args=%s "
        .. "(rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))

    -- First-landing: require directly-referenced sequence to be a master.
    local nested = Sequence.find(clip.nested_sequence_id)
    assert(nested, string.format(
        "ToggleClipChannel: clip %s nested sequence %s not found",
        clip_id, tostring(clip.nested_sequence_id)))
    assert(nested.kind == "master", string.format(
        "ToggleClipChannel: clip %s references a kind='%s' sequence; per-clip "
        .. "channel overrides are first-landing-supported only when the "
        .. "clip directly references a master (multi-level inheritance "
        .. "deferred). Refusing rather than guessing which leaf master "
        .. "owns the channel state.",
        clip_id, tostring(nested.kind)))

    -- INV-5 bounds (defense-in-depth; the resolver also asserts).
    local channel_count = Sequence.count_master_audio_channels(clip.nested_sequence_id)
    assert(channel_index < channel_count, string.format(
        "ToggleClipChannel: channel_index %d out of bounds for master %s "
        .. "(has %d audio channels). INV-5.",
        channel_index, clip.nested_sequence_id, channel_count))

    local existing = Override.find(clip_id, channel_index)
    local capture = {
        sequence_id    = sequence_id,
        clip_id        = clip_id,
        channel_index  = channel_index,
    }

    if existing then
        -- Flip enabled in-place. gain_db stays put.
        capture.prior_existed = true
        capture.prior_enabled = existing.enabled
        capture.prior_gain_db = existing.gain_db
        Override.update({
            clip_id       = clip_id,
            channel_index = channel_index,
            enabled       = not existing.enabled,
            gain_db       = existing.gain_db,
        })
        log.event("ToggleClipChannel: clip=%s ch=%d enabled %s -> %s",
            clip_id, channel_index,
            tostring(existing.enabled), tostring(not existing.enabled))
    else
        -- First toggle: materialize inherited and flip.
        local inh_enabled, inh_gain_db =
            Sequence.get_master_channel_state(clip.nested_sequence_id, channel_index)
        capture.prior_existed = false
        Override.insert({
            clip_id       = clip_id,
            channel_index = channel_index,
            enabled       = not inh_enabled,
            gain_db       = inh_gain_db,
        })
        log.event("ToggleClipChannel: clip=%s ch=%d materialized "
            .. "inherited(enabled=%s,gain=%s) -> enabled=%s",
            clip_id, channel_index, tostring(inh_enabled),
            tostring(inh_gain_db), tostring(not inh_enabled))
    end

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", sequence_id)

    return capture
end

--- Reverse a previous M.execute.
function M.undo(capture)
    assert(type(capture) == "table",
        "ToggleClipChannel.undo: capture table required")
    if capture.prior_existed then
        Override.update({
            clip_id       = capture.clip_id,
            channel_index = capture.channel_index,
            enabled       = capture.prior_enabled,
            gain_db       = capture.prior_gain_db,
        })
    else
        Override.delete(capture.clip_id, capture.channel_index)
    end

    local Signals = require("core.signals")
    Signals.emit("sequence_content_changed", capture.sequence_id)
end

-- ---------------------------------------------------------------------------
-- M.register — command_manager wiring.
-- ---------------------------------------------------------------------------

local SPEC = {
    args = {
        sequence_id   = { required = true },
        clip_id       = { required = true },
        channel_index = { required = true },
    },
    persisted = {
        prior_existed  = false,
        prior_enabled  = false,
        prior_gain_db  = 0.0,
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["ToggleClipChannel"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("ToggleClipChannel: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("prior_existed", cap.prior_existed)
        command:set_parameter("prior_enabled", cap.prior_enabled or false)
        command:set_parameter("prior_gain_db", cap.prior_gain_db or 0.0)
        return true
    end

    command_undoers["ToggleClipChannel"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            sequence_id   = args.sequence_id,
            clip_id       = args.clip_id,
            channel_index = args.channel_index,
            prior_existed = args.prior_existed and true or false,
            prior_enabled = args.prior_enabled and true or false,
            prior_gain_db = args.prior_gain_db or 0.0,
        })
        return true
    end

    return {
        executor = command_executors["ToggleClipChannel"],
        undoer   = command_undoers["ToggleClipChannel"],
        spec     = SPEC,
    }
end

return M
