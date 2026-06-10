--- Regression test: audio scroll position survives project reopen.
--
-- Joe's repro (2026-06-09): scrolled the audio pane, killed JVE,
-- restarted — the scroll was gone. In-process equivalent: scroll the
-- audio pane, let the throttle-persist fire, reopen the project via
-- OpenProject (full close → open cascade, same save points and
-- restore path a cold start runs), then verify the position is intact
-- in the DB, the model, and on screen.
--
-- Domain contract under test (no implementation names): after the user
-- scrolls the audio timeline pane and the project is closed and
-- reopened, the audio pane shows the same vertical position, and that
-- position is what the project file remembers.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_scroll_persistence_reopen.lua

local ui = require("synthetic.integration.ui_test_env")

print("=== test_scroll_persistence_reopen ===")

local _, info = ui.launch({
    project_name = "Scroll Persistence Test",
})
local seq_id = info.sequences[1].id
local db_path = info.db_path

local command_manager = require("core.command_manager")
local qt = qt_constants  -- luacheck: globals qt_constants

-- Make the audio pane scrollable: grow the template's audio tracks tall
-- enough that the content exceeds the pane viewport. SetTrackHeights is
-- the same command a real track-resize drag persists through.
print("  growing audio tracks until the pane is scrollable...")
local Track = require("models.track")
local audio_tracks = Track.find_by_sequence(seq_id, "AUDIO")
assert(#audio_tracks > 0, "template sequence has no audio tracks")
local heights = {}
for _, t in ipairs(audio_tracks) do
    heights[t.id] = 400
end
local hr = command_manager.execute("SetTrackHeights", {
    project_id    = info.project.id,
    sequence_id   = seq_id,
    track_heights = heights,
})
assert(hr and hr.success, "SetTrackHeights failed: "
    .. tostring(hr and hr.error_message or "(nil)"))
-- Track heights are read at sequence load; reopen so the timeline lays
-- out the taller tracks from a cold load (same as launching with them).
local hreopen = command_manager.execute("OpenProject", { project_path = db_path })
assert(hreopen and hreopen.success, "OpenProject (heights reload) failed: "
    .. tostring(hreopen and hreopen.error_message or "(nil)"))
ui.pump(600)

local panel = require("ui.timeline.timeline_panel")
assert(panel.timeline_audio_scroll,
    "timeline panel has no audio scroll area — UI not built?")

local function widget_audio_scroll()
    return qt.CONTROL.GET_SCROLL_AREA_V_SCROLL(panel.timeline_audio_scroll)
end

local function db_audio_scroll()
    local Sequence = require("models.sequence")
    local seq = Sequence.load(seq_id)
    assert(seq, "Sequence.load failed for " .. tostring(seq_id))
    return seq.audio_scroll_offset
end

-- Ruler and track lanes must map time across the SAME pixel span, or
-- the playhead (and every clip edge) drifts horizontally between the
-- ruler and the tracks. The vertical scrollbar reserves a gutter
-- inside the panes; the ruler row mirrors it with a trailing spacer.
-- (Joe's 2026-06-09 report: playhead offset between ruler and tracks
-- after scrollbars were enabled.)
do
    local qtp = qt.PROPERTIES
    local ruler_w = qtp.GET_SIZE(panel.ruler_widget)
    local video_w = qtp.GET_SIZE(panel.video_widget)
    local audio_w = qtp.GET_SIZE(panel.audio_widget)
    assert(ruler_w == video_w and ruler_w == audio_w, string.format(
        "time→x span mismatch: ruler=%spx video=%spx audio=%spx — the "
        .. "playhead and clip edges will not line up between the ruler "
        .. "and the track lanes",
        tostring(ruler_w), tostring(video_w), tostring(audio_w)))
end
print("  ruler and track lanes share one time span: OK")

-- First-open framing: a never-scrolled sequence shows V1 (video tracks
-- stack with V1 at the content bottom, so the video pane must sit at
-- its maximum) and A1 (audio pane at the top). Guards the 2026-06-07
-- "V1 isn't visible on first open" symptom.
do
    local v_value, v_max = qt_get_scroll_area_v_metrics(panel.timeline_video_scroll)  -- luacheck: globals qt_get_scroll_area_v_metrics
    assert(v_value == v_max, string.format(
        "first open must show V1 (video pane at bottom): value=%s max=%s",
        tostring(v_value), tostring(v_max)))
    assert(widget_audio_scroll() == 0,
        "first open must show A1 (audio pane at top)")
end
print("  first-open framing shows V1 and A1: OK")

-- Scroll the audio pane through the gesture entry point — the same
-- boundary a wheel event or scrollbar drag lands on. The value is
-- clamped to the real scrollable range, so a non-zero result proves
-- the pane really scrolled.
local SCROLL_TARGET = 120
print("  scrolling audio pane...")
panel.user_scroll_pane_to("audio", SCROLL_TARGET)
ui.pump(100)

local scrolled_to = widget_audio_scroll()
assert(scrolled_to and scrolled_to > 0, string.format(
    "audio pane did not scroll (widget=%s) — content not taller than "
    .. "viewport? add more tracks", tostring(scrolled_to)))
print(string.format("    audio pane at %d", scrolled_to))

-- Let the throttle-persist window elapse so the position reaches the DB
-- (this is the state a user is in when they kill the app after pausing
-- for a moment).
ui.pump(600)
local persisted = db_audio_scroll()
assert(persisted == scrolled_to, string.format(
    "pre-reopen persist lost the scroll: pane at %d but project file "
    .. "remembers %s", scrolled_to, tostring(persisted)))
print(string.format("    project file remembers %d", persisted))

-- Reopen the project: full close → open cascade, the same restore path
-- a cold start runs (and the same save points that can clobber).
print("  reopening project...")
local reopen = command_manager.execute("OpenProject", { project_path = db_path })
assert(reopen and reopen.success, "OpenProject (reopen) failed: "
    .. tostring(reopen and reopen.error_message or "(nil)"))
ui.pump(800)  -- restore is async: rebuild, layout, deferred scroll apply

-- The contract: position survived, everywhere the user can observe it.
local db_after = db_audio_scroll()
assert(db_after == scrolled_to, string.format(
    "REGRESSION: project reopen destroyed the saved audio scroll — "
    .. "project file had %d before reopen, %s after. (Joe's repro: "
    .. "scroll audio, kill, restart, scroll gone.)",
    scrolled_to, tostring(db_after)))

local widget_after = widget_audio_scroll()
assert(widget_after == scrolled_to, string.format(
    "REGRESSION: audio pane not restored after reopen — was at %d, "
    .. "now shows %s (project file says %s)",
    scrolled_to, tostring(widget_after), tostring(db_after)))

print(string.format("    survived reopen: pane=%d file=%d",
    widget_after, db_after))

require("synthetic.helpers.blank_project").cleanup(db_path)
ui.cleanup()
print("✅ test_scroll_persistence_reopen.lua passed")
