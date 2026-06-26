--- SetClipChannelGain command.
---
--- Args: { sequence_id, clip_id, master_track_id, gain_db }
---   sequence_id is the clip's owner_sequence_id (rule 2.29).
--- Mutation:
---   - No prior row: INSERT (master_track_id, inherited_enabled, gain_db).
---     Materializing inherited_enabled (rule 2.13) keeps "enable state
---     under user control" once a row exists; we never let SQLite's
---     implicit DEFAULT introduce a phantom value.
---   - Prior row: UPDATE gain_db; enabled untouched.
--- Undo: prior gain_db (or row-absence sentinel).
--- Signal: sequence_content_changed(sequence_id).
---
--- First-landing scope: clip.sequence_id must be kind='master'.
---
--- @file set_clip_channel_gain.lua

local M = {}

local Clip      = require("models.clip")
local Sequence  = require("models.sequence")
local Track     = require("models.track")
local Override  = require("models.clip_channel_override")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "SetClipChannelGain: '%s' is required (rule 2.29)", name))
    return v
end

local function load_clip_directly_on_master(sequence_id, clip_id)
    local clip = Clip.load_row(clip_id)
    assert(clip, string.format(
        "SetClipChannelGain: clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "SetClipChannelGain: sequence_id mismatch — clip %s owner=%s, args=%s "
        .. "(rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))
    local nested = Sequence.find(clip.sequence_id)
    assert(nested, string.format(
        "SetClipChannelGain: clip %s nested sequence %s not found",
        clip_id, tostring(clip.sequence_id)))
    assert(nested.kind == "master", string.format(
        "SetClipChannelGain: clip %s references kind='%s' sequence; "
        .. "first-landing supports per-clip channel overrides only when "
        .. "the clip directly references a master.",
        clip_id, tostring(nested.kind)))
    return clip
end

local function assert_track_is_master_audio(master_track_id, master_seq_id)
    local track = Track.load(master_track_id)
    assert(track, string.format(
        "SetClipChannelGain: master_track %s not found", master_track_id))
    assert(track.sequence_id == master_seq_id, string.format(
        "SetClipChannelGain: master_track %s belongs to sequence %s, "
        .. "not the referenced master %s",
        master_track_id, tostring(track.sequence_id), master_seq_id))
    assert(track.track_type == "AUDIO", string.format(
        "SetClipChannelGain: master_track %s is %s, not AUDIO",
        master_track_id, tostring(track.track_type)))
end

function M.execute(args)
    assert(type(args) == "table", "SetClipChannelGain.execute: args table required")
    local sequence_id     = require_string_arg(args, "sequence_id")
    local clip_id         = require_string_arg(args, "clip_id")
    local master_track_id = require_string_arg(args, "master_track_id")
    local gain_db = args.gain_db
    assert(type(gain_db) == "number", string.format(
        "SetClipChannelGain: gain_db must be a number; got %s",
        tostring(gain_db)))

    local clip = load_clip_directly_on_master(sequence_id, clip_id)
    assert_track_is_master_audio(master_track_id, clip.sequence_id)

    local existing = Override.find(clip_id, master_track_id)
    local capture = {
        sequence_id     = sequence_id,
        clip_id         = clip_id,
        master_track_id = master_track_id,
    }

    if existing then
        capture.prior_existed = true
        capture.prior_enabled = existing.enabled
        capture.prior_gain_db = existing.gain_db
        Override.update({
            clip_id         = clip_id,
            master_track_id = master_track_id,
            enabled         = existing.enabled,
            gain_db         = gain_db,
        })
        log.event("SetClipChannelGain: clip=%s track=%s gain %s -> %s",
            clip_id, master_track_id,
            tostring(existing.gain_db), tostring(gain_db))
    else
        local inh_enabled = Sequence.get_master_channel_state(master_track_id)
        capture.prior_existed = false
        Override.insert({
            clip_id         = clip_id,
            master_track_id = master_track_id,
            enabled         = inh_enabled,
            gain_db         = gain_db,
        })
        log.event("SetClipChannelGain: clip=%s track=%s new override gain=%s "
            .. "(materialized enabled=%s)",
            clip_id, master_track_id, tostring(gain_db), tostring(inh_enabled))
    end

    return capture
end

function M.undo(capture)
    assert(type(capture) == "table",
        "SetClipChannelGain.undo: capture table required")
    if capture.prior_existed then
        Override.update({
            clip_id         = capture.clip_id,
            master_track_id = capture.master_track_id,
            enabled         = capture.prior_enabled,
            gain_db         = capture.prior_gain_db,
        })
    else
        Override.delete(capture.clip_id, capture.master_track_id)
    end
end

local SPEC = {
    args = {
        sequence_id     = { required = true },
        clip_id         = { required = true },
        master_track_id = { required = true },
        gain_db         = { required = true },
    },
    persisted = {
        prior_existed = { kind = "boolean" },
        prior_enabled = { kind = "boolean" },
        prior_gain_db = { kind = "number" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SetClipChannelGain"] = function(command)
        local args = command:get_all_parameters()
        local ok, capture_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("SetClipChannelGain: " .. tostring(capture_or_err))
            return false, tostring(capture_or_err)
        end
        local cap = capture_or_err
        command:set_parameter("prior_existed", cap.prior_existed)
        if cap.prior_existed then
            assert(type(cap.prior_enabled) == "boolean",
                "SetClipChannelGain: prior_existed=true but prior_enabled missing/non-boolean")
            assert(type(cap.prior_gain_db) == "number",
                "SetClipChannelGain: prior_existed=true but prior_gain_db missing/non-number")
            command:set_parameter("prior_enabled", cap.prior_enabled)
            command:set_parameter("prior_gain_db", cap.prior_gain_db)
        end
        return true
    end

    command_undoers["SetClipChannelGain"] = function(command)
        local args = command:get_all_parameters()
        local prior_existed = args.prior_existed and true or false
        local undo_args = {
            sequence_id     = args.sequence_id,
            clip_id         = args.clip_id,
            master_track_id = args.master_track_id,
            prior_existed   = prior_existed,
        }
        if prior_existed then
            assert(type(args.prior_enabled) == "boolean",
                "SetClipChannelGain.undo: prior_existed=true but prior_enabled missing")
            assert(type(args.prior_gain_db) == "number",
                "SetClipChannelGain.undo: prior_existed=true but prior_gain_db missing")
            undo_args.prior_enabled = args.prior_enabled
            undo_args.prior_gain_db = args.prior_gain_db
        end
        M.undo(undo_args)
        return true
    end

    return {
        executor = command_executors["SetClipChannelGain"],
        undoer   = command_undoers["SetClipChannelGain"],
        spec     = SPEC,
    }
end

return M
