--- ReorderMasterChannel — move a master AUDIO channel (master track) to
--- a new ordinal position within its sequence.
---
--- The mutation is a re-numbering of `tracks.track_index` within the
--- sequence's AUDIO track set. Schema `UNIQUE(sequence_id, track_type,
--- track_index)` (schema.sql:242) forbids two tracks holding the same
--- index, so the rewrite is done as a single SQL transaction: park the
--- moved track at a sentinel index, shift the affected range up or
--- down by one, then settle the moved track at its new position.
---
--- Args:
---   track_id          — the master AUDIO track to move
---   new_track_index   — 1-based target position within the sequence's
---                       AUDIO tracks
---   sequence_id, project_id — injected by command_manager
---
--- Persisted (for undo):
---   prev_track_index  — original 1-based position
---
--- Not bindable on its own; the bindable wrapper is `MoveChannel` (an
--- offset-based command that resolves the focused channel and computes
--- the absolute target index). Drag UX in the inspector calls this
--- command directly with the absolute drop target.
---
--- @file reorder_master_channel.lua

local M = {}

local watchers = require("core.watchers")
local Track    = require("models.track")
local log      = require("core.logger").for_area("commands")

local SPEC = {
    args = {
        track_id        = { required = true, kind = "string" },
        new_track_index = { required = true, kind = "number" },
        sequence_id     = {},  -- injected
        project_id      = { required = true, kind = "string" },
    },
    persisted = {
        prev_track_index = { kind = "number" },
    },
    -- Track-property mutation only; clips don't move. UI refresh rides
    -- the sequence-level watcher fanout.
    mutates_clips = false,
}

--- Notify every AUDIO track in the sequence — any of them may have
--- moved, and the inspector's channel list is re-pulled on the
--- sequence-level fanout regardless. Belt-and-suspenders: also fire
--- per-track so a focused-track listener (e.g. the timeline track
--- header) re-reads its label position.
local function notify_audio_tracks(sequence_id)
    local tracks = Track.find_by_sequence(sequence_id, "AUDIO")
    for _, t in ipairs(tracks) do
        watchers.notify_track(t.id, sequence_id)
    end
    watchers.notify_sequence(sequence_id)
end

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "ReorderMasterChannel: track_id required")
    assert(type(args.new_track_index) == "number",
        "ReorderMasterChannel: new_track_index must be a number")

    local track = Track.load(args.track_id)
    assert(track, string.format(
        "ReorderMasterChannel: track %s not found", args.track_id))

    local prev_index = Track.reorder_audio_within_sequence(
        track.sequence_id, args.track_id, args.new_track_index)

    log.event("ReorderMasterChannel: track=%s %d->%d (sequence=%s)",
        args.track_id, prev_index, args.new_track_index, track.sequence_id)

    if prev_index ~= args.new_track_index then
        notify_audio_tracks(track.sequence_id)
    end

    return { prev_track_index = prev_index }
end

function M.undo(capture)
    assert(type(capture) == "table" and capture.track_id and capture.prev_track_index,
        "ReorderMasterChannel.undo: capture {track_id, prev_track_index} required")

    local track = Track.load(capture.track_id)
    assert(track, string.format(
        "ReorderMasterChannel.undo: track %s not found", capture.track_id))

    if track.track_index == capture.prev_track_index then return end

    Track.reorder_audio_within_sequence(
        track.sequence_id, capture.track_id, capture.prev_track_index)

    notify_audio_tracks(track.sequence_id)
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["ReorderMasterChannel"] = function(command)
        local args = command:get_all_parameters()
        local result = M.execute(args)
        command:set_parameter("prev_track_index", result.prev_track_index)
        return true
    end

    command_undoers["ReorderMasterChannel"] = function(command)
        local args = command:get_all_parameters()
        M.undo({
            track_id         = args.track_id,
            prev_track_index = args.prev_track_index,
        })
        return true
    end

    return {
        executor = command_executors["ReorderMasterChannel"],
        undoer   = command_undoers["ReorderMasterChannel"],
        spec     = SPEC,
    }
end

return M
