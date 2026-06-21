--- T-FR004 (025) — M/S button click-zone width (spec 025 FR-004).
---
--- The Mute (M) and Solo (S) buttons in the track header were too narrow
--- to click reliably. FR-004 widens their click zone to a 24px target
--- (label text size unchanged, toggle behavior unchanged).
---
--- Domain assertion: every track's M/S button click zone is at least the
--- FR-004 target width. 24 is the spec value, NOT read from the code — a
--- regression that shrinks the buttons back toward the old 16px must fail
--- this test.
---
--- Runs in --test mode against the real binary so the real header layout
--- code runs and we read the actual configured button geometry.

require('test_env')
local ui = require("synthetic.integration.ui_test_env")

print("=== test_025_sm_button_click_zone ===")

local Track = require("models.track")

-- FR-004 target click-zone width (px). Spec-derived, not code-derived.
local FR004_MIN_SM_WIDTH = 24

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
    assert(layout.sm_width >= FR004_MIN_SM_WIDTH, string.format(
        "%s: M/S button click zone is %dpx — FR-004 requires >= %dpx so the "
        .. "buttons are reliably clickable", tr.label, layout.sm_width,
        FR004_MIN_SM_WIDTH))
    print(string.format("  PASS: %s M/S click zone = %dpx (>= %d)",
        tr.label, layout.sm_width, FR004_MIN_SM_WIDTH))
end

print("✅ test_025_sm_button_click_zone.lua passed")
