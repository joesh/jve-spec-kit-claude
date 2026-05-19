--- ScrollTimelineViewport — gesture-driven horizontal pan of the
--- displayed timeline's viewport.
---
--- Default binding: plain wheel/trackpad horizontal scroll on the
--- timeline ruler and the timeline view body. The wheel handlers do
--- the pixel→frame conversion (including any fractional-pixel
--- accumulator) and dispatch this command with whole frames only;
--- timeline_state's set_viewport_start_time clamps to the sequence
--- extent.
---
--- Non-undoable: viewport pan is view-state, not an edit.
---
--- @file scroll_timeline_viewport.lua
local M = {}

local SPEC = {
    undoable = false,
    mutates_clips = false,
    no_project_context = true,
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
    args = {
        delta_frames = { required = true, kind = "number" },
    },
    keyboard = {
        category     = "Gesture",
        display_name = "Scroll Timeline Viewport",
        description  = "Pan the displayed timeline's horizontal viewport by "
                    .. "a relative frame count. Bound by default to plain "
                    .. "wheel/trackpad horizontal scroll on the ruler and "
                    .. "the timeline view.",
    },
}

function M.register(executors, undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        local delta = args.delta_frames
        assert(type(delta) == "number" and delta == math.floor(delta),
            "ScrollTimelineViewport: delta_frames must be an integer "
            .. "(handler does the pixel→frame conversion; pass whole frames)")
        assert(delta ~= 0,
            "ScrollTimelineViewport: delta_frames must be non-zero "
            .. "(handler must filter no-op gestures rather than dispatch)")

        local ts = require("ui.timeline.timeline_state")
        local new_start = ts.get_viewport_start_time() + delta
        ts.set_viewport_start_time(new_start)
        return true
    end

    return {
        ScrollTimelineViewport = { executor = executor, spec = SPEC },
    }
end

return M
