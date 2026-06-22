--- T-FR004 (025) — M/S button width stays compact (spec 025 FR-004).
---
--- The Mute (M) and Solo (S) buttons are stacked vertically, so the reliable
--- way to make them easier to hit is to grow the click zone DOWNWARD (each
--- fills half the header height), NOT to widen them. FR-004 explicitly does
--- not widen these buttons.
---
--- Domain assertion: every track's M/S button width stays at the compact value
--- — a regression that widens it (the earlier mistake) must fail this test. The
--- vertical fill (each button takes half the header) is verified visually; there
--- is no widget-height getter to assert it black-box here.
---
--- Runs in --test mode against the real binary so the real header layout code
--- runs and we read the actual configured button geometry.

require('test_env')
local ui = require("synthetic.integration.ui_test_env")

print("=== test_025_sm_button_click_zone ===")

local Track = require("models.track")

-- FR-004 cap on the M/S button width (px): kept compact, never widened. The
-- click zone grows vertically (each button fills half the header), not sideways.
local FR004_MAX_SM_WIDTH = 16

local DB = "/tmp/jve/test_025_sm_button_click_zone.jvp"
local _, project_info = ui.launch({
    db_path      = DB,
    project_name = "SM Click Zone",
})
local sequence_id = project_info.sequences[1].id

local function track_id_at(track_type, idx)
    local id = Track.find_at(sequence_id, track_type, idx)
    assert(id, string.format(
        "template missing %s track at index %d", track_type, idx))
    return id
end

-- Film 24fps template ships V1-V3 + A1-A3 → covers both the video and
-- audio header code paths (audio rows trail a waveform toggle; the M/S
-- stack must be the FR-004 width on both row kinds).
local TRACKS = {
    { id = track_id_at("VIDEO", 1), label = "video row V1" },
    { id = track_id_at("AUDIO", 1), label = "audio row A1" },
}

local timeline_panel = require("ui.timeline.timeline_panel")
assert(type(timeline_panel.get_track_header_layout_for_test) == "function",
    "timeline_panel must expose get_track_header_layout_for_test(track_id)")

for _, tr in ipairs(TRACKS) do
    local layout = timeline_panel.get_track_header_layout_for_test(tr.id)
    assert(layout, string.format(
        "%s: no header layout snapshot (track not loaded?)", tr.label))
    assert(type(layout.sm_width) == "number", string.format(
        "%s: header layout did not report sm_width", tr.label))
    assert(layout.sm_width <= FR004_MAX_SM_WIDTH, string.format(
        "%s: M/S button is %dpx wide — FR-004 keeps these compact (<= %dpx); "
        .. "the click zone grows vertically, not by widening", tr.label,
        layout.sm_width, FR004_MAX_SM_WIDTH))
    print(string.format("  PASS: %s M/S button width = %dpx (<= %d, compact)",
        tr.label, layout.sm_width, FR004_MAX_SM_WIDTH))
end

print("✅ test_025_sm_button_click_zone.lua passed")
