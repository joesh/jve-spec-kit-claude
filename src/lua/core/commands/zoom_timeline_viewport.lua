--- ZoomTimelineViewport — gesture-driven continuous zoom of the
--- displayed timeline's viewport.
---
--- Default binding: dragging either end of the zoom-scroller thumb
--- (the horizontal scroller below the track lanes). The handler does
--- the pixel→frame conversion and dispatches absolute frames; the
--- anchor frame is the viewport edge NOT being dragged, so that edge
--- holds still while the other stretches.
---
--- Unlike TimelineZoomIn/Out (discrete ×2 steps), this command sets an
--- absolute duration — the gesture is continuous.
---
--- Non-undoable: viewport zoom is view-state, not an edit.
---
--- @file zoom_timeline_viewport.lua
local M = {}

-- Same floor as TimelineZoomIn: a viewport narrower than this is
-- sub-frame-per-pixel noise, not a useful zoom level.
local MIN_DURATION_FRAMES = 30

local SPEC = {
    undoable = false,
    mutates_clips = false,
    no_project_context = true,
    skip_clip_snapshot = true,
    skip_selection_snapshot = true,
    args = {
        duration_frames = { required = true, kind = "number" },
        anchor_frame    = { required = true, kind = "number" },
    },
    keyboard = {
        category     = "Gesture",
        display_name = "Zoom Timeline Viewport",
        description  = "Set the displayed timeline's viewport duration "
                    .. "(zoom) with one edge anchored. Bound by default "
                    .. "to dragging the ends of the zoom-scroller thumb.",
    },
}

function M.register(executors, undoers, _db)
    local function executor(command)
        local args = command:get_all_parameters()
        local duration = args.duration_frames
        local anchor = args.anchor_frame
        assert(type(duration) == "number" and duration == math.floor(duration),
            "ZoomTimelineViewport: duration_frames must be an integer "
            .. "(handler does the pixel→frame conversion)")
        assert(type(anchor) == "number" and anchor == math.floor(anchor),
            "ZoomTimelineViewport: anchor_frame must be an integer frame")

        -- Domain clamp, not a fallback: a continuous drag can request
        -- arbitrarily small durations; the floor is the zoom limit.
        if duration < MIN_DURATION_FRAMES then
            duration = MIN_DURATION_FRAMES
        end

        local ts = require("ui.timeline.timeline_state")
        ts.set_viewport_duration(duration, {
            zoom_around = "frame",
            anchor_frame = anchor,
        })
        return true
    end

    return {
        ZoomTimelineViewport = { executor = executor, spec = SPEC },
    }
end

return M
