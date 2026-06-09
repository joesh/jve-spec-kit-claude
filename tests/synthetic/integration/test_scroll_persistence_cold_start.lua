--- Regression test: audio scroll position survives an app restart.
--
-- Joe's repro (2026-06-09): scrolled the audio pane, killed JVE,
-- restarted — the scroll was gone. The in-process reopen test
-- (test_scroll_persistence_reopen.lua) does NOT catch this: with the
-- window already realized, scroll restore lands correctly. The loss
-- needs a COLD start, where restore races widget layout.
--
-- Two processes:
--   seed phase (child JVE, spawned by this script): creates the
--     project, makes the audio pane scrollable, scrolls it, lets the
--     persist throttle fire, exits — the "scrolled then killed" state.
--   verify phase (this process): cold-starts on that project file the
--     way a real restart does, then asserts the audio pane shows the
--     saved position and the project file still remembers it.
--
-- Domain contract: after the user scrolls the audio timeline pane and
-- restarts the app, the audio pane shows the same vertical position,
-- and the project file is not rewritten to a different one.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_scroll_persistence_cold_start.lua

local DB_PATH = "/tmp/jve/test_scroll_cold_start.jvp"
local SEED_MARKER = "/tmp/jve/test_scroll_cold_start.seeded"
local SCROLL_TARGET = 120

--------------------------------------------------------------------------------
-- Seed phase (child process)
--------------------------------------------------------------------------------

if os.getenv("JVE_SCROLL_TEST_PHASE") == "seed" then
    local ui = require("synthetic.integration.ui_test_env")
    local command_manager = require("core.command_manager")

    local _, info = ui.launch({
        project_name = "Scroll Cold Start Test",
        db_path = DB_PATH,
    })
    local seq_id = info.sequences[1].id

    -- Grow the audio tracks so the pane is scrollable (SetTrackHeights
    -- is what a real track-resize drag persists through), then reopen
    -- so the timeline lays the taller tracks out.
    local Track = require("models.track")
    local audio_tracks = Track.find_by_sequence(seq_id, "AUDIO")
    assert(#audio_tracks > 0, "seed: template sequence has no audio tracks")
    local heights = {}
    for _, t in ipairs(audio_tracks) do heights[t.id] = 400 end
    local hr = command_manager.execute("SetTrackHeights", {
        project_id    = info.project.id,
        sequence_id   = seq_id,
        track_heights = heights,
    })
    assert(hr and hr.success, "seed: SetTrackHeights failed: "
        .. tostring(hr and hr.error_message or "(nil)"))
    local ro = command_manager.execute("OpenProject", { project_path = DB_PATH })
    assert(ro and ro.success, "seed: heights reload reopen failed")
    ui.pump(600)

    -- Scroll the audio pane through the gesture entry point — the same
    -- boundary a wheel event or scrollbar drag lands on (clamped to the
    -- real range, so reaching the target proves it scrolled).
    local panel = require("ui.timeline.timeline_panel")
    assert(panel.timeline_audio_scroll, "seed: no audio scroll area")
    panel.user_scroll_pane_to("audio", SCROLL_TARGET)
    ui.pump(100)
    local at = qt_constants.CONTROL.GET_SCROLL_AREA_V_SCROLL(
        panel.timeline_audio_scroll)
    assert(at == SCROLL_TARGET, string.format(
        "seed: audio pane at %s, wanted %d — pane not scrollable enough?",
        tostring(at), SCROLL_TARGET))

    -- Let the persist throttle fire, then verify the file remembers it
    -- BEFORE the kill — so the verify phase failure can only blame the
    -- restart path.
    ui.pump(600)
    local seq = require("models.sequence").load(seq_id)
    assert(seq.audio_scroll_offset == SCROLL_TARGET, string.format(
        "seed: persist throttle wrote %s, wanted %d",
        tostring(seq.audio_scroll_offset), SCROLL_TARGET))

    -- Hand the sequence id to the verify phase.
    local mf = assert(io.open(SEED_MARKER, "w"))
    mf:write(seq_id)
    mf:close()

    print("✅ seed phase complete: audio at "
        .. SCROLL_TARGET .. ", persisted, exiting (the kill)")
    return
end

--------------------------------------------------------------------------------
-- Verify phase (this process = the restart)
--------------------------------------------------------------------------------

print("=== test_scroll_persistence_cold_start ===")

os.remove(SEED_MARKER)

-- Locate our own binary from package.path (bundle-relative) and this
-- script's own absolute path, so the child runs the exact same build
-- and script regardless of CWD.
local bundle_lua = package.path:match("([^;]*/jve%.app/Contents/Resources)/src/lua")
assert(bundle_lua, "cannot locate jve.app bundle from package.path")
local jve_bin = bundle_lua:gsub("/Resources$", "/MacOS/jve")
local self_script = debug.getinfo(1, "S").source:match("^@(.+)$")
assert(self_script and self_script:sub(1, 1) == "/", string.format(
    "need own absolute script path for the child process, got %s — "
    .. "run with an absolute --test path", tostring(self_script)))

print("  spawning seed JVE (scroll + persist + kill)...")
local cmd = string.format(
    "JVE_SCROLL_TEST_PHASE=seed %q --test %q > /tmp/jve/scroll_seed_phase.log 2>&1",
    jve_bin, self_script)
local rc = os.execute(cmd)
assert(rc == 0 or rc == true, "seed phase failed — see /tmp/jve/scroll_seed_phase.log")

local mf = assert(io.open(SEED_MARKER, "r"),
    "seed phase left no marker — see /tmp/jve/scroll_seed_phase.log")
local seq_id = mf:read("*a")
mf:close()
assert(seq_id and seq_id ~= "", "seed marker empty")

-- Cold start: open the seeded project exactly the way a restart does.
print("  cold-starting on the seeded project...")
local ui = require("synthetic.integration.ui_test_env")
ui.launch_existing(DB_PATH)
ui.pump(800)  -- restore is async: rebuild, layout, deferred scroll apply

local panel = require("ui.timeline.timeline_panel")
assert(panel.timeline_audio_scroll, "no audio scroll area after cold start")
local widget_after = qt_constants.CONTROL.GET_SCROLL_AREA_V_SCROLL(
    panel.timeline_audio_scroll)

local seq = require("models.sequence").load(seq_id)
local db_after = seq.audio_scroll_offset

assert(db_after == SCROLL_TARGET, string.format(
    "REGRESSION: restart destroyed the saved audio scroll — project "
    .. "file had %d at kill, %s after restart. (Joe's repro: scroll "
    .. "audio, kill, restart, scroll gone.)",
    SCROLL_TARGET, tostring(db_after)))

assert(widget_after == SCROLL_TARGET, string.format(
    "REGRESSION: audio pane not restored after restart — saved %d, "
    .. "pane shows %s (project file says %s)",
    SCROLL_TARGET, tostring(widget_after), tostring(db_after)))

print(string.format("    survived restart: pane=%d file=%d",
    widget_after, db_after))

os.remove(SEED_MARKER)
require("synthetic.helpers.blank_project").cleanup(DB_PATH)
ui.cleanup()
print("✅ test_scroll_persistence_cold_start.lua passed")
