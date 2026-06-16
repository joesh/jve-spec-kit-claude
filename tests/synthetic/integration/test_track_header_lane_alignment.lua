-- Integration: a track's header row must sit at the same on-screen height
-- as its clip lane (run via `jve --test`).
--
-- The video/audio boundary is a single midline shared by two columns: the
-- track-header column and the clip-lane column. Each column carries the
-- boundary in its own scroll area. The first video track (V1) anchors its
-- BOTTOM to that midline in BOTH columns; the first audio track (A1) anchors
-- its TOP to it. So when the video section is taller than its stacked track
-- rows, V1's header bottom and V1's clip-lane bottom must land on the same
-- screen Y — likewise A1's tops.
--
-- Regression: the header column fills its viewport (a layout stretch shoves
-- V1 to the section bottom) but the clip-lane scroll area was not
-- widgetResizable, so Qt sized the painted lane widget to its content and
-- top-justified it. V1's bottom-anchored lane then floated near the section
-- top while V1's header stayed at the section bottom — a visible drift that
-- grew with the video section height. This pins the on-screen alignment.
--
-- Real widgets (the full timeline panel over a real project): we compare
-- MAP_TO_GLOBAL screen coordinates, the only thing the user actually sees.

print("=== test_track_header_lane_alignment ===")

local ui = require("synthetic.integration.ui_test_env")
ui.launch({ project_name = "Track Header Lane Alignment" })

local state = require("ui.timeline.timeline_state")
local timeline_panel = require("ui.timeline.timeline_panel")

ui.pump(300)

local video_tracks = state.get_video_tracks()
local audio_tracks = state.get_audio_tracks()
assert(#video_tracks >= 1, "test needs at least one video track")
assert(#audio_tracks >= 1, "test needs at least one audio track")

-- Make the video section much taller than a single ~30px track row, so the
-- header's bottom-anchor and the lane's bottom-anchor must actively agree
-- rather than coincide by accident at a tight fit.
state.set_video_audio_split_ratio(0.72)
timeline_panel.apply_video_audio_split(state.get_video_audio_split_ratio())
ui.pump(300)

local v1 = video_tracks[1]   -- V1: bottom anchored to the midline
local a1 = audio_tracks[1]   -- A1: top anchored to the midline

local v1_header = timeline_panel.track_header_widget(v1.id)
local a1_header = timeline_panel.track_header_widget(a1.id)
assert(v1_header, "no header widget built for V1")
assert(a1_header, "no header widget built for A1")
assert(timeline_panel.video_widget, "video clip-lane widget missing")
assert(timeline_panel.audio_widget, "audio clip-lane widget missing")

local function bottom_global_y(widget)
    local _, h = qt_constants.PROPERTIES.GET_SIZE(widget)
    assert(h and h > 0, "widget has no height (not shown?)")
    local _, gy = qt_constants.WIDGET.MAP_TO_GLOBAL(widget, 0, h)
    return gy
end

local function top_global_y(widget)
    local _, gy = qt_constants.WIDGET.MAP_TO_GLOBAL(widget, 0, 0)
    return gy
end

-- Allow a couple px for scroll-area frame/scrollbar differences between the
-- two columns; the regression is tens of px, far outside this band.
local TOL = 3

-- ── V1: header bottom aligns with clip-lane bottom (the midline) ──────
-- The video lane renders bottom_to_top with its origin at the lane widget's
-- bottom, so the lane widget's bottom edge IS V1's bottom on screen.
local v1_header_bottom = bottom_global_y(v1_header)
local v1_lane_bottom   = bottom_global_y(timeline_panel.video_widget)
print(string.format("  V1 header bottom = %d, V1 lane bottom = %d", v1_header_bottom, v1_lane_bottom))
assert(math.abs(v1_header_bottom - v1_lane_bottom) <= TOL, string.format(
    "V1 header and clip lane misaligned at the midline: header bottom %d vs lane bottom %d (Δ%d)",
    v1_header_bottom, v1_lane_bottom, math.abs(v1_header_bottom - v1_lane_bottom)))
print("  PASS V1 header/lane bottoms coincide")

-- ── A1: header top aligns with clip-lane top (the midline) ────────────
local a1_header_top = top_global_y(a1_header)
local a1_lane_top   = top_global_y(timeline_panel.audio_widget)
print(string.format("  A1 header top = %d, A1 lane top = %d", a1_header_top, a1_lane_top))
assert(math.abs(a1_header_top - a1_lane_top) <= TOL, string.format(
    "A1 header and clip lane misaligned at the midline: header top %d vs lane top %d (Δ%d)",
    a1_header_top, a1_lane_top, math.abs(a1_header_top - a1_lane_top)))
print("  PASS A1 header/lane tops coincide")

print("\nPASS test_track_header_lane_alignment")
