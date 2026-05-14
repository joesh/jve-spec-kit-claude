--- ToggleTrackWaveformDisplay command.
---
--- Flips the per-track "draw audio waveform in this lane" UI preference.
--- Routed as a command (not a direct track_state call) so the keymap layer
--- can bind it to a shortcut — every header button must be reachable from
--- the keyboard. View state, not project data → NOT undoable.
---
--- Emits `track_waveform_display_changed(track_id, new_val_int)` after the
--- mutation lands so header buttons restyle via pull-on-signal (rule 3.0),
--- matching the ToggleTrackPreference / SetSyncMode pattern.
---
--- @file toggle_track_waveform_display.lua

local M = {}

local SPEC = {
    undoable = false,
    -- Keyboard customisation metadata, consumed by command_registry at
    -- load time (data-driven config — rule 1.5). Listing this in a SPEC
    -- rather than a separate registrations file keeps display name +
    -- description colocated with the command implementation.
    keyboard = {
        category    = "Timeline ▸ Track Header",
        display_name = "Toggle Track Waveform Display",
        description = "Show or hide the audio waveform inside this track's "
            .. "clip lane (UI preference, not project data).",
    },
    args = {
        track_id   = { required = true },
        value      = {},  -- optional: if absent, flips current value
        project_id = { required = true },
    },
}

function M.execute(args)
    assert(type(args.track_id) == "string" and args.track_id ~= "",
        "ToggleTrackWaveformDisplay: track_id required")

    local track_state = require("ui.timeline.state.track_state")
    local track = track_state.get_by_id(args.track_id)
    assert(track, string.format(
        "ToggleTrackWaveformDisplay: track %s not found", tostring(args.track_id)))
    assert(track.track_type == "AUDIO", string.format(
        "ToggleTrackWaveformDisplay: only audio tracks have a waveform-display "
        .. "toggle; track %s is %s", tostring(args.track_id), tostring(track.track_type)))

    local prev_val = track_state.get_waveform_enabled(args.track_id)
    local new_val
    if args.value == nil then
        new_val = not prev_val
    else
        -- Strict boolean only: `args.value and true or false` would silently
        -- coerce 0 / "false" / "" to true (Lua truthiness). NSF: surface
        -- bad input rather than producing a wrong write.
        assert(type(args.value) == "boolean", string.format(
            "ToggleTrackWaveformDisplay: value must be a boolean if provided; "
            .. "got %s (%s). Truthy non-booleans are NOT accepted as 'on'.",
            tostring(args.value), type(args.value)))
        new_val = args.value
    end
    track_state.set_waveform_enabled(args.track_id, new_val)

    require("core.signals").emit("track_waveform_display_changed",
        args.track_id, new_val and 1 or 0)

    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors["ToggleTrackWaveformDisplay"] = function(command)
        return M.execute(command:get_all_parameters())
    end
    return {
        executor = command_executors["ToggleTrackWaveformDisplay"],
        spec     = SPEC,
    }
end

return M
