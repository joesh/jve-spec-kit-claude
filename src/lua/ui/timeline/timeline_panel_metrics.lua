--- Pure timeline-panel metrics: row sizing + scroll-target arithmetic.
---
--- Extracted from timeline_panel.lua so the metrics surface can be
--- exercised by tests without pulling Qt into the require graph. The
--- panel itself re-exports this as `M.metrics`; external callers use
--- either entry point interchangeably.
---
--- No Qt deps. No state. Pure functions over the row-sizing constants.

local M = {}

-- Minimum height for any track row. Drag handler enforces this at the
-- input boundary; helpers below assert it as a precondition.
M.MIN_TRACK_HEIGHT = 30

-- Header column layout: each track header is
--   [ header widget ][ RESIZE_EDGE_PX-tall drag edge widget ]
-- The two together must measure exactly `track_height` so the headers
-- column and the corresponding clip lane line up pixel-for-pixel.
M.RESIZE_EDGE_PX = 4

-- Width of the trailing alignment cell on a track header row. Audio rows
-- render it as the waveform-toggle "W"; video rows render an empty spacer
-- of the same width so the M/S stack ends at the same x on both kinds.
M.TRAILING_ALIGNMENT_PX = 16

local function assert_track_height(h, caller)
    assert(type(h) == "number" and h >= M.MIN_TRACK_HEIGHT,
        string.format("%s: track_height must be number >= %d, got %s",
            caller, M.MIN_TRACK_HEIGHT, tostring(h)))
end

function M.content_to_header(track_height)
    assert_track_height(track_height, "content_to_header")
    return track_height - M.RESIZE_EDGE_PX
end

-- header_row_total and lane_row_total both collapse mathematically to
-- track_height; kept named-separately to document the per-column
-- structure (header column = widget + edge; lane column = single lane).
function M.header_row_total(track_height)
    return M.content_to_header(track_height) + M.RESIZE_EDGE_PX
end

function M.lane_row_total(track_height)
    assert_track_height(track_height, "lane_row_total")
    return track_height
end

function M.row_trailing_alignment_width(track_type)
    assert(track_type == "VIDEO" or track_type == "AUDIO",
        "row_trailing_alignment_width: track_type must be VIDEO|AUDIO")
    return M.TRAILING_ALIGNMENT_PX
end

return M
