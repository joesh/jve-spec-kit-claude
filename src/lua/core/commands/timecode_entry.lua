--- Timecode-entry commands (spec 025 FR-002).
---
--- Three keybound activation commands open the timeline's TC field in an
--- entry mode:
---   * IncrementTimecode  (`+`, `Num+`)  → offset mode, prefix "+"
---   * DecrementTimecode  (`-`, `Num-`)  → offset mode, prefix "-"
---   * GoToTimecode       (`=`)          → absolute-TC mode, prefix "="
---
--- Each command stops playback and asks the view to activate the field —
--- both via signals (MVC: the command never reaches into the panel/engine
--- directly). The actual move happens later, when the user presses Enter:
--- the panel parses the field with `core.timecode_input` (which resolves
--- fps + sign) and dispatches the action chosen by `M.compute_action`.
---
--- None of these are undoable (`SPEC.undoable = false`) — activating a
--- field is not a model edit, and the move they trigger is an existing
--- command (SetPlayhead / Nudge) that records itself as appropriate.
---
--- @file timecode_entry.lua

local M = {}

local Signals = require("core.signals")

local VALID_PREFIX = { ["+"] = true, ["-"] = true, ["="] = true }

--- Pure dispatch decision for a committed timecode entry.
---
--- Decision B (interactive, spec 025 FR-002): the panel has ALREADY parsed
--- the field text via `core.timecode_input` into an integer `value_frames`,
--- so this function does NO parsing (stays fps-free) and NO I/O. It only
--- chooses which EXISTING command to run:
---   * prefix "="        → value_frames is the ABSOLUTE target frame
---   * prefix "+" / "-"  → value_frames is the SIGNED offset in frames
---
--- "=" always navigates the playhead (SetPlayhead). "+"/"-" with a selection
--- delegates to `NudgeSelection` — the same selection-aware dispatcher the
--- comma/period keys use, which routes edges→BatchRippleEdit (ripple) and
--- clips→Nudge and owns undo. We pass only direction + magnitude;
--- NudgeSelection reads the live selection itself. "+"/"-" with NO selection
--- nudges the playhead off `current_frame`.
---
--- A bare "+"/"-" (zero offset) over a selection is a no-op and returns nil
--- (NudgeSelection requires a positive magnitude). A zero-offset playhead
--- move (`=`current, or relative with no selection) lands on the same frame
--- and is harmless, so it still returns a SetPlayhead action.
---
--- @param prefix string: one of "+", "-", "="
--- @param value_frames number: integer frame count (absolute, or signed offset)
--- @param has_selection boolean: whether any clip or edge is selected
--- @param current_frame number|nil: playhead frame (required for relative-no-selection)
--- @return table|nil: { command = string, args = table }, or nil for a no-op
function M.compute_action(prefix, value_frames, has_selection, current_frame)
    assert(VALID_PREFIX[prefix], string.format(
        "timecode_entry.compute_action: prefix must be '+', '-', or '='; got %s", tostring(prefix)))
    assert(type(value_frames) == "number" and value_frames == math.floor(value_frames), string.format(
        "timecode_entry.compute_action: value_frames must be an integer frame count; got %s",
        tostring(value_frames)))
    assert(type(has_selection) == "boolean", string.format(
        "timecode_entry.compute_action: has_selection must be a boolean; got %s", tostring(has_selection)))

    -- Absolute go-to: navigate the playhead regardless of selection.
    if prefix == "=" then
        return { command = "SetPlayhead", args = { playhead_position = value_frames } }
    end

    -- Relative + selection: move the selection via the canonical dispatcher.
    if has_selection then
        if value_frames == 0 then
            return nil  -- bare "+"/"-": zero-magnitude nudge is a no-op
        end
        local direction = value_frames > 0 and 1 or -1
        return {
            command = "NudgeSelection",
            args = { direction = direction, magnitude = math.abs(value_frames) },
        }
    end

    -- Relative + no selection: nudge the playhead.
    assert(type(current_frame) == "number", string.format(
        "timecode_entry.compute_action: current_frame required for a relative move with no selection; got %s",
        tostring(current_frame)))
    return { command = "SetPlayhead", args = { playhead_position = current_frame + value_frames } }
end

--- Stop playback and ask the view to open the TC field in entry mode.
--- Pure signal emission (MVC) — the panel listens and focuses/prefills the
--- field; the playback engine listens and stops. Requires an active
--- project + sequence (you cannot enter a timecode with no timeline).
local function activate(command_name, prefix, args)
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        command_name .. ": project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        command_name .. ": sequence_id required (no active timeline = nothing to enter a timecode against)")
    Signals.emit("request_stop_playback")
    Signals.emit("tc_entry_activate", prefix)
    return true
end

function M.increment(args) return activate("IncrementTimecode", "+", args) end
function M.decrement(args) return activate("DecrementTimecode", "-", args) end
function M.go_to(args)     return activate("GoToTimecode",      "=", args) end

local function make_spec(display_name, description)
    return {
        undoable = false,
        keyboard = {
            category     = "Timeline ▸ Navigation",
            display_name = display_name,
            description  = description,
        },
        args = {
            project_id  = { required = true },
            sequence_id = { required = true },
        },
    }
end

function M.register(executors, _undoers, _db, _set_last_error)
    executors["IncrementTimecode"] = function(command) return M.increment(command:get_all_parameters()) end
    executors["DecrementTimecode"] = function(command) return M.decrement(command:get_all_parameters()) end
    executors["GoToTimecode"]      = function(command) return M.go_to(command:get_all_parameters()) end

    return {
        IncrementTimecode = {
            executor = executors["IncrementTimecode"],
            spec     = make_spec("Increment Timecode",
                "Open the timeline timecode field in +offset mode; Enter moves the playhead "
                .. "(or selection) forward by the typed amount."),
        },
        DecrementTimecode = {
            executor = executors["DecrementTimecode"],
            spec     = make_spec("Decrement Timecode",
                "Open the timeline timecode field in -offset mode; Enter moves the playhead "
                .. "(or selection) backward by the typed amount."),
        },
        GoToTimecode = {
            executor = executors["GoToTimecode"],
            spec     = make_spec("Go To Timecode",
                "Open the timeline timecode field in absolute mode; Enter navigates the "
                .. "playhead to the typed timecode."),
        },
    }
end

return M
