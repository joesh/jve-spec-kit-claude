#!/usr/bin/env luajit
--- Video and audio track header rows must end at the same x-coordinate.
---
--- Audio rows trail with a "W" waveform toggle (HDR.WAVE wide). Video
--- rows have no waveform — without a matching trailing spacer the
--- video buttons (M/S stack) end HDR.WAVE px LEFT of the audio
--- buttons, making the column look ragged.
---
--- Domain property: for both VIDEO and AUDIO rows, the trailing
--- alignment width is the same nonzero value.

require("test_env")

print("=== test_video_row_trailing_alignment.lua ===")

local m = require("ui.timeline.timeline_panel_metrics")
assert(type(m.row_trailing_alignment_width) == "function",
    "panel_metrics.row_trailing_alignment_width(track_type) missing")

local v = m.row_trailing_alignment_width("VIDEO")
local a = m.row_trailing_alignment_width("AUDIO")
assert(type(v) == "number" and v > 0,
    string.format("VIDEO trailing width must be a positive number; got %s", tostring(v)))
assert(type(a) == "number" and a > 0,
    string.format("AUDIO trailing width must be a positive number; got %s", tostring(a)))
assert(v == a, string.format(
    "VIDEO trailing alignment width (%d) must equal AUDIO trailing alignment "
    .. "width (%d) so both column rows end at the same x. Mismatch detaches "
    .. "the video M/S stack from the audio M/S stack visually.", v, a))

print(string.format("  trailing alignment widths equal: V=%d  A=%d", v, a))
print("\n✅ test_video_row_trailing_alignment.lua passed")
