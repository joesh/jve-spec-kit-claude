--- Every track-header button must carry a non-empty hover tooltip so the
--- icon-only controls (M, S, 🔒, ∿//🚫, V1/A1, W) are discoverable. The
--- ripple-sync mode button additionally must explain all three modes
--- (ripple, cut, off) in its tooltip because the cycle has no other label.
---
--- Drives the real binary in --test mode so the tooltips reach actual Qt
--- widgets (cf. test_eliding_label_tooltip for the read pattern).

require('test_env')
local ui = require("synthetic.integration.ui_test_env")
local qt = require("core.qt_constants")
local Track = require("models.track")

print("=== test_track_header_tooltips ===")

local DB = "/tmp/jve/test_track_header_tooltips.jvp"
local _, project_info = ui.launch({
    db_path      = DB,
    project_name = "Header Tooltips",
})
local sequence_id = project_info.sequences[1].id

local function track_id_at(track_type, idx)
    local id = Track.find_at(sequence_id, track_type, idx)
    assert(id, string.format(
        "template missing %s track at index %d", track_type, idx))
    return id
end

local timeline_panel = require("ui.timeline.timeline_panel")
assert(type(timeline_panel.get_track_header_buttons_for_test) == "function",
    "timeline_panel must expose get_track_header_buttons_for_test(track_id)")

local function tooltip_of(widget, label)
    assert(widget, label .. ": widget missing in header refs")
    local tip = qt.PROPERTIES.GET_TOOLTIP(widget)
    assert(tip and #tip > 0, label .. ": tooltip is empty (got " .. tostring(tip) .. ")")
    return tip
end

local function check_track(track_id, track_label, expect_wave)
    local btns = timeline_panel.get_track_header_buttons_for_test(track_id)
    assert(btns, track_label .. ": no buttons returned")

    tooltip_of(btns.mute_btn, track_label .. " mute")
    tooltip_of(btns.solo_btn, track_label .. " solo")
    tooltip_of(btns.lock_btn, track_label .. " lock")
    tooltip_of(btns.src_btn,  track_label .. " src patch")
    tooltip_of(btns.rec_btn,  track_label .. " rec patch")

    local sync_tip = tooltip_of(btns.sync_mode_btn, track_label .. " sync_mode")
    local lower = sync_tip:lower()
    assert(lower:find("ripple", 1, true),
        track_label .. " sync_mode tooltip must mention 'ripple': " .. sync_tip)
    assert(lower:find("cut", 1, true),
        track_label .. " sync_mode tooltip must mention 'cut': " .. sync_tip)
    assert(lower:find("off", 1, true),
        track_label .. " sync_mode tooltip must mention 'off': " .. sync_tip)

    if expect_wave then
        tooltip_of(btns.wave_btn, track_label .. " waveform toggle")
    end
end

check_track(track_id_at("VIDEO", 1), "V1", false)
check_track(track_id_at("AUDIO", 1), "A1", true)

-- Accessor must reject empty/missing track_id (2.32 — assert paths get tested).
for _, bad in ipairs({ "", nil }) do
    local ok, err = pcall(timeline_panel.get_track_header_buttons_for_test, bad)
    assert(not ok,
        "get_track_header_buttons_for_test(" .. tostring(bad) .. ") must assert")
    assert(tostring(err):find("track_id required", 1, true),
        "assert message must mention 'track_id required'; got: " .. tostring(err))
end

print("\n✅ test_track_header_tooltips passed")
