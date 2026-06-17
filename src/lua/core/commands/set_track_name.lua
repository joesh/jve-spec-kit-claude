--- SetTrackName command (023 Feature B).
---
--- Sets a track's user-facing name (a rename). The name is the user's
--- OVERRIDE: clearing it (empty/whitespace) stores NULL, so the display
--- reverts to the derived label (a synced master's recorder iXML channel
--- name, else blank — see ui/timeline/track_header_label). Renames belong
--- on the undo stack.
---
--- Signal: track_name_changed(track_id, new_name, prev_name) — new_name and
--- prev_name are the stored values (a string, or nil when unset).
---
--- @file set_track_name.lua

local M = {}

local Track = require("models.track")
local log   = require("core.logger").for_area("commands")

local SPEC = {
    keyboard = {
        category     = "Timeline ▸ Track Header",
        display_name = "Set Track Name",
        description  = "Rename a track. Undoable. Clearing the name reverts "
            .. "to the derived label. Bind with name=STRING.",
    },
    args = {
        track_id    = { required = true },
        name        = { required = true },  -- may be "" to clear the override
        sequence_id = {},  -- injected by execute_interactive in UI context
        project_id  = { required = true },
    },
    -- prev_name persists as a string; "" is the sentinel for "was unset"
    -- (a nil parameter would not survive serialization).
    persisted = {
        prev_name = { kind = "string" },
    },
    -- A rename touches one track property — no clip-level timeline mutations.
    -- Drives UI refresh via the track_name_changed signal instead.
    mutates_clips = false,
}

-- Empty / whitespace-only input clears the override (stored as NULL).
local function normalize(name)
    assert(type(name) == "string", string.format(
        "SetTrackName: name must be a string; got %s", type(name)))
    local trimmed = name:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil end
    return trimmed
end

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "SetTrackName: track_id required")
    local new_name = normalize(args.name)

    local track = Track.load(args.track_id)
    assert(track, string.format(
        "SetTrackName: track %s not found", tostring(args.track_id)))

    local prev_name = track.name
    track.name = new_name
    assert(track:save(), string.format(
        "SetTrackName: track:save() failed for track=%s", tostring(args.track_id)))

    log.event("SetTrackName: track=%s %s->%s",
        args.track_id, tostring(prev_name), tostring(new_name))

    local Signals = require("core.signals")
    Signals.emit("track_name_changed", args.track_id, new_name, prev_name)

    return { prev_name = prev_name }
end

function M.undo(capture)
    assert(type(capture) == "table" and capture.track_id,
        "SetTrackName.undo: capture.track_id required")

    local track = Track.load(capture.track_id)
    assert(track, string.format(
        "SetTrackName.undo: track %s not found", tostring(capture.track_id)))

    local current_name = track.name
    track.name = capture.prev_name
    assert(track:save(), string.format(
        "SetTrackName.undo: track:save() failed for track=%s",
        tostring(capture.track_id)))

    local Signals = require("core.signals")
    Signals.emit("track_name_changed",
        capture.track_id, capture.prev_name, current_name)
end

function M.register(command_executors, command_undoers, _db, _set_last_error)
    command_executors["SetTrackName"] = function(command)
        local args = command:get_all_parameters()
        local result = M.execute(args)
        -- "" sentinel preserves "was unset" across persistence (nil would drop).
        command:set_parameter("prev_name", result.prev_name or "")
        return true
    end

    command_undoers["SetTrackName"] = function(command)
        local args = command:get_all_parameters()
        local prev = args.prev_name
        if prev == "" then prev = nil end  -- "" sentinel -> unset
        M.undo({ track_id = args.track_id, prev_name = prev })
        return true
    end

    return {
        executor = command_executors["SetTrackName"],
        undoer   = command_undoers["SetTrackName"],
        spec     = SPEC,
    }
end

return M
