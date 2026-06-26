--- MoveChannel — the bindable offset-based wrapper around the
--- ReorderMasterChannel mutation. Resolves the currently-focused master
--- channel from the Inspector's channel-list renderer, computes the
--- target display index from the offset, and dispatches the underlying
--- (non-bindable) reorder command via the inspectable.
---
--- Bound twice, by convention, in `keymaps/default.jvekeys`:
---     MoveChannel  offset=+1   (move down — to a higher display index)
---     MoveChannel  offset=-1   (move up   — to a lower  display index)
---
--- Not undoable as a standalone — it lays no undo entry of its own; the
--- ReorderMasterChannel it dispatches goes on the undo stack via the
--- command_manager.execute_interactive path inside `:move_channel`.
---
--- @file move_channel.lua

local M = {}

local SPEC = {
    keyboard = {
        category     = "Inspector ▸ Channels",
        display_name = "Move Channel",
        description  = "Move the focused master channel by `offset` slots "
            .. "(use offset=+1 to move down, offset=-1 to move up). The "
            .. "underlying reorder is undoable.",
    },
    args = {
        offset = { required = true, kind = "number" },
    },
    -- This command is a UX dispatcher: the persisted mutation rides on the
    -- ReorderMasterChannel it forwards to. No direct mutation here.
    undoable      = false,
    mutates_clips = false,
}

function M.execute(args)
    assert(type(args.offset) == "number"
            and args.offset == math.floor(args.offset)
            and args.offset ~= 0,
        "MoveChannel: offset must be a non-zero integer")

    local channel_list_renderer = require("ui.inspector.channel_list_renderer")
    local focused = channel_list_renderer.get_focused_channel()
    assert(focused and focused.inspectable and focused.track_id,
        "MoveChannel: no channel is focused — click a channel name in the "
        .. "Inspector first")

    local Track = require("models.track")
    local track = Track.load(focused.track_id)
    assert(track, string.format(
        "MoveChannel: focused track %s no longer exists", focused.track_id))

    local audio_tracks = Track.find_by_sequence(track.sequence_id, "AUDIO")
    local audio_count = #audio_tracks
    local new_index = track.track_index + args.offset
    assert(new_index >= 1 and new_index <= audio_count, string.format(
        "MoveChannel: cannot move channel %d by %+d — only %d channel "
        .. "slot(s) available", track.track_index, args.offset, audio_count))

    local ok, err = focused.inspectable:move_channel(focused.track_id, new_index)
    assert(ok, err)
    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["MoveChannel"] = function(command)
        return M.execute(command:get_all_parameters())
    end
    return {
        executor = command_executors["MoveChannel"],
        spec     = SPEC,
    }
end

return M
