--- SetTimelineDecodeMode — set the EMP decode-mode pipeline state.
---
--- Invoked from the ruler / timeline-view playhead drag handlers at
--- the transitions:
---   * first drag-move during a press → "scrub"
---   * release while engine playing   → "play"
---   * release while engine parked    → "park"
--- The mode selection is a handler-layer decision (it depends on the
--- engine's current play state); this command centralizes the EMP
--- side-effect so a future gesture editor can rebind which event
--- triggers each transition.
---
--- Non-undoable: decoder mode is a pipeline state, not a project edit.
---
--- @file set_timeline_decode_mode.lua
local M = {}

local VALID_MODES = { scrub = true, park = true, play = true }

local SPEC = {
    undoable = false,
    mutates_clips = false,
    no_project_context = true,
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
    args = {
        mode = { required = true, kind = "string" },
    },
    keyboard = {
        category     = "Gesture",
        display_name = "Set Timeline Decode Mode",
        description  = "Set the EMP decoder mode to scrub / park / play. "
                    .. "Invoked from ruler-drag transitions; exposed as a "
                    .. "command so the future gesture editor can rebind "
                    .. "which input event drives each transition.",
    },
}

function M.register(executors, undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        local mode = args.mode
        assert(VALID_MODES[mode], string.format(
            "SetTimelineDecodeMode: mode must be 'scrub'|'park'|'play'; got %s",
            tostring(mode)))
        local emp = require("core.qt_constants").EMP
        assert(emp and emp.SET_DECODE_MODE, "SetTimelineDecodeMode: "
            .. "core.qt_constants.EMP.SET_DECODE_MODE missing (binding not wired)")
        emp.SET_DECODE_MODE(mode)
        return true
    end

    return {
        SetTimelineDecodeMode = { executor = executor, spec = SPEC },
    }
end

return M
