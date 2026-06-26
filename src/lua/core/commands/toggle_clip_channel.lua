--- ToggleClipChannel command.
---
--- Args: { sequence_id, clip_id, master_track_id }
---   sequence_id is the clip's owner_sequence_id (rule 2.29).
---   master_track_id is the master AUDIO track whose mix-state this
---   override targets (identity-stable; reordering master channels does
---   not rewrite override rows, and deleting the track CASCADEs the row
---   out of clip_channel_override automatically).
--- Pre: clip exists; clip.owner_sequence_id == sequence_id; clip directly
---   references a master (clip.sequence_id.kind == 'master'); track exists
---   and lives on that master and is AUDIO.
--- Mutation:
---   - No clip_channel_override row for (clip_id, master_track_id):
---     INSERT row with enabled = NOT inherited_enabled, gain_db =
---     inherited_gain_db (rule 2.13 — materialize inherited; never let
---     SQL DEFAULT 0 sneak through).
---   - Row exists: UPDATE enabled to its opposite. gain_db untouched.
--- Undo: row's prior state (or row-absence sentinel).
--- Signal: sequence_content_changed(sequence_id).
---
--- First-landing limit: clip.sequence_id must be kind='master'.
--- Multi-level inheritance (clip → nested → master) is deferred.
---
--- @file toggle_clip_channel.lua

local M = {}

local Clip      = require("models.clip")
local Sequence  = require("models.sequence")
local Track     = require("models.track")
local Override  = require("models.clip_channel_override")
local log       = require("core.logger").for_area("commands")

local function require_string_arg(args, name)
    local v = args[name]
    assert(type(v) == "string" and v ~= "", string.format(
        "ToggleClipChannel: '%s' is required (rule 2.29)", name))
    return v
end

local function load_clip_directly_on_master(sequence_id, clip_id)
    local clip = Clip.load_row(clip_id)
    assert(clip, string.format(
        "ToggleClipChannel: clip %s not found", clip_id))
    assert(clip.owner_sequence_id == sequence_id, string.format(
        "ToggleClipChannel: sequence_id mismatch — clip %s owner=%s, args=%s "
        .. "(rule 2.29)",
        clip_id, tostring(clip.owner_sequence_id), tostring(sequence_id)))
    local nested = Sequence.find(clip.sequence_id)
    assert(nested, string.format(
        "ToggleClipChannel: clip %s nested sequence %s not found",
        clip_id, tostring(clip.sequence_id)))
    assert(nested.kind == "master", string.format(
        "ToggleClipChannel: clip %s references a kind='%s' sequence; "
        .. "per-clip channel overrides are first-landing-supported only "
        .. "when the clip directly references a master (multi-level "
        .. "inheritance deferred).",
        clip_id, tostring(nested.kind)))
    return clip
end

local function assert_track_is_master_audio(master_track_id, master_seq_id)
    local track = Track.load(master_track_id)
    assert(track, string.format(
        "ToggleClipChannel: master_track %s not found", master_track_id))
    assert(track.sequence_id == master_seq_id, string.format(
        "ToggleClipChannel: master_track %s belongs to sequence %s, "
        .. "not the referenced master %s",
        master_track_id, tostring(track.sequence_id), master_seq_id))
    assert(track.track_type == "AUDIO", string.format(
        "ToggleClipChannel: master_track %s is %s, not AUDIO",
        master_track_id, tostring(track.track_type)))
end

--- Pure-logic entry point. Returns an undo capture.
function M.execute(args)
    assert(type(args) == "table", "ToggleClipChannel.execute: args table required")
    local sequence_id     = require_string_arg(args, "sequence_id")
    local clip_id         = require_string_arg(args, "clip_id")
    local master_track_id = require_string_arg(args, "master_track_id")

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
            enabled         = not existing.enabled,
            gain_db         = existing.gain_db,
        })
        log.event("ToggleClipChannel: clip=%s track=%s enabled %s -> %s",
            clip_id, master_track_id,
            tostring(existing.enabled), tostring(not existing.enabled))
    else
        local inh_enabled, inh_gain_db =
            Sequence.get_master_channel_state(master_track_id)
        capture.prior_existed = false
        Override.insert({
            clip_id         = clip_id,
            master_track_id = master_track_id,
            enabled         = not inh_enabled,
            gain_db         = inh_gain_db,
        })
        log.event("ToggleClipChannel: clip=%s track=%s materialized "
            .. "inherited(enabled=%s,gain=%s) -> enabled=%s",
            clip_id, master_track_id, tostring(inh_enabled),
            tostring(inh_gain_db), tostring(not inh_enabled))
    end

    return capture
end

function M.undo(capture)
    assert(type(capture) == "table",
        "ToggleClipChannel.undo: capture table required")
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
    },
    persisted = {
        prior_existed  = { kind = "boolean" },
        prior_enabled  = { kind = "boolean" },
        prior_gain_db  = { kind = "number" },
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
        if cap.prior_existed then
            assert(type(cap.prior_enabled) == "boolean",
                "ToggleClipChannel: prior_existed=true but prior_enabled missing/non-boolean")
            assert(type(cap.prior_gain_db) == "number",
                "ToggleClipChannel: prior_existed=true but prior_gain_db missing/non-number")
            command:set_parameter("prior_enabled", cap.prior_enabled)
            command:set_parameter("prior_gain_db", cap.prior_gain_db)
        end
        return true
    end

    command_undoers["ToggleClipChannel"] = function(command)
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
                "ToggleClipChannel.undo: prior_existed=true but prior_enabled missing")
            assert(type(args.prior_gain_db) == "number",
                "ToggleClipChannel.undo: prior_existed=true but prior_gain_db missing")
            undo_args.prior_enabled = args.prior_enabled
            undo_args.prior_gain_db = args.prior_gain_db
        end
        M.undo(undo_args)
        return true
    end

    return {
        executor = command_executors["ToggleClipChannel"],
        undoer   = command_undoers["ToggleClipChannel"],
        spec     = SPEC,
    }
end

return M
