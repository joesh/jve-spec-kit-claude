--- SetMarkAndTrimIfClip — the source-monitor I/O-key command (spec 019).
---
--- Resolves the playhead frame from the active monitor (when not
--- supplied) and dispatches a nested command per source_viewer mode:
---   * live_bound_clip → OverwriteTrimEdge or RippleTrimEdge (per
---     `edit_mode.get_trim_mode()`) on the loaded clip's edge — the
---     clip's source_in/out IS the mark in live-bound mode.
---   * staged_sequence → SetMark on the staged sequence row (so the
---     mark mutation rides the proper undo stack).
---   * neutral         → no-op (nothing loaded).
---
--- `undoable = false` because the dispatch is *always* a nested command
--- which carries its own undo entry; the outer wrapper has nothing to
--- undo and shouldn't pollute the stack with empty entries.
---
--- Keymap: `"I" = "SetMarkAndTrimIfClip in @source_monitor"` (and "O").
--- Plain SetMark stays bound to @timeline / @timeline_monitor as a pure
--- sequence-row mark mutator. Scopes are disjoint — no precedence rules.
---
--- @file set_mark_and_trim_if_clip.lua
local M = {}

local SPEC = {
    undoable      = false,
    mutates_clips = false,
    args = {
        _positional = {},
        sequence_id = { kind = "string" },
        frame       = { kind = "number" },
    },
}

local function resolve_frame(args)
    local frame = args.frame or args.playhead
    if frame == nil then
        local sm = require("ui.panel_manager").get_active_sequence_monitor()
        assert(sm and sm.engine,
            "SetMarkAndTrimIfClip: no active sequence monitor for playhead")
        frame = sm.engine:get_position()
    end
    assert(type(frame) == "number",
        "SetMarkAndTrimIfClip: frame must be a number")
    return frame
end

local function dispatch_live_bound(which, frame)
    local sv      = require("ui.source_viewer")
    local clip_id = assert(sv.get_live_clip_id(),
        "SetMarkAndTrimIfClip: live_bound_clip mode with no live_clip_id")
    local clip = require("models.clip").load(clip_id)
    assert(clip, string.format(
        "SetMarkAndTrimIfClip: live-bound clip %s no longer exists — "
        .. "sequence_content_changed listener should have unloaded",
        tostring(clip_id)))

    local edge    = (which == "in") and "left" or "right"
    local current = (which == "in") and clip.source_in or clip.source_out
    local delta   = frame - current
    if delta == 0 then return end  -- mark already at playhead

    -- Collapse/invert presses are routine UX (wrong key, boundary),
    -- not invariant violations. Reject before the model layer's loud
    -- duration_frames > 0 assert. Duration math goes through the same
    -- canonical helper the trim commands use.
    local new_duration = require("models.clip")
        .compute_trim_duration(clip, edge, delta)
    if new_duration <= 0 then
        require("core.logger").for_area("commands").event(
            "SetMarkAndTrimIfClip: mark rejected — would collapse clip %s "
            .. "(which=%s frame=%d current=%d delta=%d duration=%d → new_duration=%d)",
            tostring(clip_id), which, frame, current, delta,
            clip.duration, new_duration)
        return
    end

    local cmd_name = (require("core.edit_mode").get_trim_mode() == "ripple")
        and "RippleTrimEdge" or "OverwriteTrimEdge"
    require("core.command_manager").execute_interactive(cmd_name, {
        clip_id      = clip.id,
        edge         = edge,
        delta_frames = delta,
        sequence_id  = clip.owner_sequence_id,
        project_id   = clip.project_id,
    })
end

local function dispatch_staged(which, frame)
    local sv = require("ui.source_viewer")
    local seq_id = assert(sv.get_staged_seq_id(),
        "SetMarkAndTrimIfClip: staged_sequence mode with no staged_seq_id")
    require("core.command_manager").execute_interactive("SetMark", {
        _positional = { which },
        sequence_id = seq_id,
        frame       = frame,
    })
end

function M.register(executors, _)
    executors["SetMarkAndTrimIfClip"] = function(command)
        local args = command:get_all_parameters()
        local pos  = args._positional or {}
        assert(#pos >= 1, "SetMarkAndTrimIfClip: positional arg required (in/out)")
        local which = pos[1]
        assert(which == "in" or which == "out", string.format(
            "SetMarkAndTrimIfClip: positional must be 'in' or 'out'; got %q",
            tostring(which)))

        local mode = require("ui.source_viewer").get_mode()
        if mode == "neutral" then return { success = true } end

        local frame = resolve_frame(args)
        if mode == "live_bound_clip" then
            dispatch_live_bound(which, frame)
        else
            dispatch_staged(which, frame)
        end
        return { success = true }
    end

    return {
        ["SetMarkAndTrimIfClip"] = {
            executor = executors["SetMarkAndTrimIfClip"],
            spec     = SPEC,
        },
    }
end

return M
