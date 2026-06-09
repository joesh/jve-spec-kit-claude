--- Regression test: audio scroll position survives switching to another
--- sequence and back.
--
-- Deterministic form of Joe's kill/restart scroll loss (2026-06-09).
-- Mechanism (evidenced on the live broken instance): after switching
-- to a sequence whose audio content is TALLER than the previous one's,
-- the pane is still clamped at the previous (short) layout until the
-- deferred scroll restore lands. Anything that saves view-state inside
-- that window — here, clicking straight on to another tab — records
-- the clamped position instead of the saved one, and the project file
-- forgets the user's scroll.
--
-- Domain contract: sequence view-state is per-sequence. Scroll a
-- sequence's audio pane, look at a different sequence, come back —
-- the audio pane is where you left it, and the project file still
-- remembers it.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_scroll_survives_tab_switch.lua

local ui = require("synthetic.integration.ui_test_env")
local command_manager = require("core.command_manager")

print("=== test_scroll_survives_tab_switch ===")

local _, info = ui.launch({
    project_name = "Scroll Tab Switch Test",
    num_sequences = 2,
    sequence_names = { "Tall Audio", "Short Audio" },
    active_sequence = 1,
})
local tall_seq = info.sequences[1].id
local short_seq = info.sequences[2].id
local db_path = info.db_path

local Track = require("models.track")
local qt = qt_constants  -- luacheck: globals qt_constants

-- Tall Audio: grow audio tracks so the pane scrolls.
-- Short Audio: shrink audio tracks so the pane has no scroll range.
local function set_audio_heights(seq_id, h)
    local tracks = Track.find_by_sequence(seq_id, "AUDIO")
    assert(#tracks > 0, "sequence has no audio tracks: " .. seq_id)
    local heights = {}
    for _, t in ipairs(tracks) do heights[t.id] = h end
    local r = command_manager.execute("SetTrackHeights", {
        project_id    = info.project.id,
        sequence_id   = seq_id,
        track_heights = heights,
    })
    assert(r and r.success, "SetTrackHeights failed: "
        .. tostring(r and r.error_message or "(nil)"))
end
set_audio_heights(tall_seq, 400)
set_audio_heights(short_seq, 30)

-- Heights are read at sequence load — reopen so both layouts come up
-- from a cold load.
local ro = command_manager.execute("OpenProject", { project_path = db_path })
assert(ro and ro.success, "reopen for heights failed")
ui.pump(600)

local panel = require("ui.timeline.timeline_panel")
assert(panel.timeline_audio_scroll, "no audio scroll area")

local function widget_audio_scroll()
    return qt.CONTROL.GET_SCROLL_AREA_V_SCROLL(panel.timeline_audio_scroll)
end
local function db_audio_scroll(seq_id)
    local seq = require("models.sequence").load(seq_id)
    return seq.audio_scroll_offset
end

-- Scroll Tall Audio's pane through the gesture entry point (the same
-- boundary a wheel event or scrollbar drag lands on) and let the
-- persist throttle fire.
local SCROLL_TARGET = 120
print("  scrolling Tall Audio's pane...")
panel.user_scroll_pane_to("audio", SCROLL_TARGET)
ui.pump(600)
assert(widget_audio_scroll() == SCROLL_TARGET, string.format(
    "Tall Audio pane did not scroll to %d (at %s) — not scrollable?",
    SCROLL_TARGET, tostring(widget_audio_scroll())))
assert(db_audio_scroll(tall_seq) == SCROLL_TARGET, string.format(
    "pre-switch persist lost the scroll: pane at %d, file remembers %s",
    SCROLL_TARGET, tostring(db_audio_scroll(tall_seq))))
print(string.format("    Tall Audio at %d, persisted", SCROLL_TARGET))

-- Look at Short Audio (its pane has no scroll range), then come back.
print("  switching to Short Audio and back...")
local s1 = command_manager.execute("OpenSequenceInTimeline",
    { sequence_id = short_seq })
assert(s1 and s1.success, "switch to Short Audio failed")
ui.pump(600)

local s2 = command_manager.execute("OpenSequenceInTimeline",
    { sequence_id = tall_seq })
assert(s2 and s2.success, "switch back to Tall Audio failed")

-- Click straight back to Short Audio — rapid tab clicking, no pause.
-- At this instant Tall Audio's pane is still where the short layout
-- clamped it (its deferred restore hasn't landed yet), and leaving a
-- tab saves its view-state.
local s3 = command_manager.execute("OpenSequenceInTimeline",
    { sequence_id = short_seq })
assert(s3 and s3.success, "rapid switch to Short Audio failed")

local s4 = command_manager.execute("OpenSequenceInTimeline",
    { sequence_id = tall_seq })
assert(s4 and s4.success, "final switch back to Tall Audio failed")
ui.pump(800)  -- restore + throttle-persist windows

-- The contract: per-sequence scroll position survived the round trip.
local db_after = db_audio_scroll(tall_seq)
assert(db_after == SCROLL_TARGET, string.format(
    "REGRESSION: tab round-trip destroyed Tall Audio's saved scroll — "
    .. "file had %d before the switch, %s after. (Restore clamped "
    .. "against the previous sequence's stale scroll range, then the "
    .. "clamped 0 was persisted over the saved value.)",
    SCROLL_TARGET, tostring(db_after)))

local widget_after = widget_audio_scroll()
assert(widget_after == SCROLL_TARGET, string.format(
    "REGRESSION: Tall Audio's pane not restored after tab round-trip "
    .. "— was at %d, now shows %s (file says %s)",
    SCROLL_TARGET, tostring(widget_after), tostring(db_after)))

print(string.format("    survived round-trip: pane=%d file=%d",
    widget_after, db_after))

require("synthetic.helpers.blank_project").cleanup(db_path)
ui.cleanup()
print("✅ test_scroll_survives_tab_switch.lua passed")
