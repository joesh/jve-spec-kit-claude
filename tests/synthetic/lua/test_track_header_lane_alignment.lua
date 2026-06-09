#!/usr/bin/env luajit

-- Regression: after the spreadsheet-style row-resize refactor, each track in
-- the headers column is `[header widget][resize edge widget]` while the
-- corresponding clip lane in the timeline view is a single block of
-- `track_height` px. The old conversion subtracted HEADER_BORDER_THICKNESS=2
-- when sizing the header widget but the resize edge is 4 px, so per-row the
-- headers column was 2 px taller than the lane. With N tracks the
-- mismatch accumulated into a visible gap between header rows and clip
-- lanes (Joe 2026-05-14, A6..A10 visibly higher than their clip rows).
--
-- Domain behavior: for ANY user-chosen track_height, the N-th track header
-- must align pixel-for-pixel with the N-th clip lane. Equivalently,
-- header_row_total(h) == lane_row_total(h) for every supported h.

require("test_env")

print("=== test_track_header_lane_alignment.lua ===")

local m = require("ui.timeline.timeline_panel_metrics")
assert(type(m.header_row_total) == "function", "metrics.header_row_total missing")
assert(type(m.lane_row_total)   == "function", "metrics.lane_row_total missing")

-- A spread of plausible track heights: default, min, tall, very tall.
local heights = { 30, 50, 64, 100, 200 }
for _, h in ipairs(heights) do
    local hdr  = m.header_row_total(h)
    local lane = m.lane_row_total(h)
    assert(hdr == lane, string.format(
        "FAIL: track_height=%d  header_row_total=%d  lane_row_total=%d  delta=%d. "
        .. "Per-row drift accumulates over N tracks and detaches the headers "
        .. "column from the clip-lane column — visible as growing whitespace "
        .. "between A_n header and A_n lane.",
        h, hdr, lane, hdr - lane))
end

print(string.format("  alignment holds for heights {%s} — OK",
    table.concat(heights, ", ")))
print("\n✅ test_track_header_lane_alignment.lua passed")
