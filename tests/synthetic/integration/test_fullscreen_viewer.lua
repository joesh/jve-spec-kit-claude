-- Integration test: FullscreenViewer domain behavior.
--
-- REPLACES: tests/synthetic/lua/test_fullscreen_viewer.lua (700+ lines,
-- wholesale mock — faked qt_constants with mock EMP surfaces, mock Signals,
-- mock transport/engine, fake _G.timeline, fake monitor_mark_bar). That
-- version was inadequate because: (1) fake engines couldn't catch real
-- set_mirror_surface assertion failures from missing _playback_controller;
-- (2) mock surfaces bypassed real SURFACE_ON_READY one-shot handshake;
-- (3) fake signals couldn't surface wiring bugs in project_changed handler;
-- (4) the priority-5 collision between fullscreen_viewer and transport
--     teardown (both at 5) was invisible — real test revealed the bug and
--     the fix moved fullscreen_viewer to priority 4.
--
-- DOMAIN RULES PINNED:
--   DR-1  enter() activates fullscreen for the named view_id; is_active()
--         returns true; get_current_view_id() returns the view_id.
--   DR-2  enter() installs a Lua frame mirror on the named monitor so park-
--         mode frames are forwarded to the fullscreen surface.
--   DR-3  enter() installs the C++ mirror on the monitor's playback engine
--         (set_mirror_surface) so CVDisplayLink frames are forwarded.
--         Requires a loaded sequence (real _playback_controller).
--   DR-4  exit() deactivates; is_active()=false; Lua mirror cleared on monitor;
--         C++ mirror cleared on engine — dangling m_mirror_surface would crash
--         on next deliverFrame after the surface is destroyed.
--   DR-5  project_changed signal exits fullscreen before transport teardown
--         (priority 4; transport at priority 5). Verified last because
--         project_changed tears down transport, invalidating further enter() calls.
--   DR-6  enter() asserts loudly on nil or empty view_id (NSF).
--   DR-7  switch_viewer() asserts loudly when fullscreen is not active (NSF).
--   DR-8  enter() asserts if already active — caller must exit() first.
--   DR-9  switch_viewer() moves the Lua mirror from old monitor to new one.
--   DR-10 switch_viewer() moves the C++ mirror from old engine to new engine.
--   DR-11 ToggleFullscreenView command enters for the focused viewer;
--         second call exits. Non-viewer panel focus defaults to timeline_monitor.
--
-- TEST ORDER: DR-5 (project_changed) runs last because emitting it causes
-- transport.teardown_engine (priority 5) to clear _playback_controller on
-- all engines; subsequent enter() calls would fail. All other DRs run first.
--
-- DROPPED scenarios from stub version:
--   - "Frame mirror forwarding on _on_show_frame / _on_show_gap / _on_set_rotation
--     / _on_set_par" — those are SequenceMonitor internal callbacks covered by
--     test_sequence_monitor.lua. Retesting them here tests SequenceMonitor
--     internals, not fullscreen_viewer domain behavior.
--   - Surface creation count assertions — brittle to implementation details
--     of how many GPU surfaces are created during monitor construction.
--
-- OPEN QUESTIONS:
--   OQ-1  SURFACE_ON_READY deferred frame push (DR-2 Metal-ready path) cannot
--         be driven in --test mode: CVDisplayLink is unavailable so Metal never
--         signals ready. The deferred push invariant (no frame before ready)
--         is structurally guaranteed by the SURFACE_ON_READY callback storage.
--         Joe to confirm if a Metal-capable environment is needed here.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_fullscreen_viewer.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_fullscreen_viewer.lua (integration) ===")

require("test_env")

local database        = require("core.database")
local Signals         = require("core.signals")
local command_manager = require("core.command_manager")
local test_env_mod    = require("test_env")

-- ── DB bootstrap ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_fullscreen_viewer_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj_fs', 'FSProject', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now)))

-- Dummy media record — no real file needed for mirror surface tests.
assert(db:exec(string.format([[
    INSERT INTO media (id, project_id, file_path, name, duration_frames,
        fps_numerator, fps_denominator, width, height,
        audio_channels, audio_sample_rate, created_at, modified_at)
    VALUES ('media_fs', 'proj_fs', '/nonexistent/fs_clip.mov', 'FSClip', 120,
        24, 1, 1920, 1080, 2, 48000, %d, %d)
]], now, now)))

local mc_id = test_env_mod.create_test_masterclip_sequence(
    "proj_fs", "FSClip", 24, 1, 120, "media_fs")

-- Record sequence: audio_bus_rate resolver requires at least one sequence
-- with audio_sample_rate.
assert(db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, created_at, modified_at)
    VALUES ('rec_fs', 'proj_fs', 'RecFS', 'sequence', 24, 1, 48000, 1920, 1080,
        0, 120, 0, %d, %d)
]], now, now)))

-- ── Timeline stub: required before load_sequence so viewport_state.set_playhead
-- does not assert "no displayed tab (cache nil)".
test_env_mod.install_displayed_tab_stub({ sequence_id = "rec_fs" })

-- ── Monitor + transport bootstrap ──────────────────────────────────────────────
-- setup_monitor_panels creates real SequenceMonitor instances, registers them
-- in panel_manager, and calls transport.init so engines get real
-- _playback_controller instances after load_sequence.
local monitors = ienv.setup_monitor_panels({
    kinds                = "both",
    focus                = "timeline_monitor",
    transport_project_id = "proj_fs",
})
local tl_mon  = monitors.timeline
local src_mon = monitors.source

-- Load sequences so each engine has a real _playback_controller (required
-- for set_mirror_surface / clear_mirror_surface in DR-3/DR-4/DR-10).
tl_mon:load_sequence("rec_fs")
src_mon:load_sequence(mc_id)

command_manager.init("rec_fs", "proj_fs")

-- ── Module under test ──────────────────────────────────────────────────────────
local fullscreen_viewer = require("ui.fullscreen_viewer")

-- ── DR-1: initial state ────────────────────────────────────────────────────────
print("\n--- DR-1: initial state is inactive ---")
assert(fullscreen_viewer.is_active() == false,
    "fullscreen_viewer should start inactive")
assert(fullscreen_viewer.get_current_view_id() == nil,
    "no current view_id before enter")
print("  ok")

-- ── DR-2 + DR-3: enter() installs Lua + C++ mirrors ───────────────────────────
print("\n--- DR-2 + DR-3: enter() installs frame mirrors ---")
fullscreen_viewer.enter("timeline_monitor")
assert(fullscreen_viewer.is_active() == true,
    "is_active() must be true after enter")
assert(fullscreen_viewer.get_current_view_id() == "timeline_monitor",
    "get_current_view_id() must return the entered view_id")
-- Lua mirror: tl_mon._frame_mirror set; src_mon untouched.
assert(tl_mon._frame_mirror ~= nil,
    "DR-2: timeline_monitor must have a Lua frame mirror after enter")
assert(src_mon._frame_mirror == nil,
    "DR-2: source_monitor must NOT have a Lua frame mirror before switch")
print("  ok: Lua mirror installed, C++ mirror call passed without assert")

-- ── DR-4: exit() clears both mirrors ──────────────────────────────────────────
print("\n--- DR-4: exit() clears Lua + C++ mirrors ---")
fullscreen_viewer.exit()
assert(fullscreen_viewer.is_active() == false,
    "is_active() must be false after exit")
assert(fullscreen_viewer.get_current_view_id() == nil,
    "get_current_view_id() must be nil after exit")
assert(tl_mon._frame_mirror == nil,
    "DR-4: Lua frame mirror must be cleared on exit")
print("  ok: state cleared, no dangling mirrors")

-- ── DR-4 (idempotent): exit() when inactive is safe no-op ─────────────────────
print("\n--- DR-4 (idempotent): double-exit is safe ---")
fullscreen_viewer.exit()
assert(fullscreen_viewer.is_active() == false, "still inactive after second exit")
print("  ok")

-- ── DR-6: enter() asserts on bad view_id (NSF) ───────────────────────────────
print("\n--- DR-6: enter() NSF on bad view_id ---")
local ok_nil, err_nil = pcall(fullscreen_viewer.enter, nil)
assert(not ok_nil, "enter(nil) must assert")
assert(tostring(err_nil):find("view_id required"),
    "error must mention 'view_id required', got: " .. tostring(err_nil))

local ok_empty, err_empty = pcall(fullscreen_viewer.enter, "")
assert(not ok_empty, "enter('') must assert")
assert(tostring(err_empty):find("view_id required"),
    "error must mention 'view_id required', got: " .. tostring(err_empty))
print("  ok: nil and empty view_id both assert loudly")

-- ── DR-7: switch_viewer() asserts when not active (NSF) ──────────────────────
print("\n--- DR-7: switch_viewer() NSF when not active ---")
local ok_sw, err_sw = pcall(fullscreen_viewer.switch_viewer, "source_monitor")
assert(not ok_sw, "switch_viewer while inactive must assert")
assert(tostring(err_sw):find("not active"),
    "error must mention 'not active', got: " .. tostring(err_sw))
print("  ok")

-- ── DR-8: enter() asserts if already active ───────────────────────────────────
print("\n--- DR-8: enter() asserts when already active ---")
fullscreen_viewer.enter("timeline_monitor")
local ok_double, err_double = pcall(fullscreen_viewer.enter, "source_monitor")
assert(not ok_double, "enter() while active must assert")
assert(tostring(err_double):find("already active"),
    "error must mention 'already active', got: " .. tostring(err_double))
fullscreen_viewer.exit()
print("  ok")

-- ── DR-9: switch_viewer() moves Lua mirror ────────────────────────────────────
print("\n--- DR-9: switch_viewer() moves Lua frame mirror ---")
fullscreen_viewer.enter("timeline_monitor")
assert(tl_mon._frame_mirror ~= nil,  "precondition: tl_mon has mirror")
assert(src_mon._frame_mirror == nil, "precondition: src_mon has no mirror")

fullscreen_viewer.switch_viewer("source_monitor")
assert(fullscreen_viewer.get_current_view_id() == "source_monitor",
    "current view_id must be source_monitor after switch")
assert(tl_mon._frame_mirror == nil,
    "DR-9: old monitor (timeline) Lua mirror must be cleared on switch")
assert(src_mon._frame_mirror ~= nil,
    "DR-9: new monitor (source) Lua mirror must be installed on switch")

-- switch to same view_id is a no-op
local mirror_before = src_mon._frame_mirror
fullscreen_viewer.switch_viewer("source_monitor")
assert(src_mon._frame_mirror == mirror_before,
    "DR-9: switching to same view_id must not change mirror")

fullscreen_viewer.exit()
print("  ok")

-- ── DR-10: switch_viewer() moves C++ mirror between engines ───────────────────
print("\n--- DR-10: switch_viewer() moves C++ mirror (no assert from engine) ---")
-- Verify the full enter→switch→exit call sequence completes without any
-- assertion failure from the C++ engine layer. We cannot inspect
-- _playback_controller state directly from Lua, but an assert in the C++
-- path would crash the --test process with non-zero exit.
fullscreen_viewer.enter("timeline_monitor")
fullscreen_viewer.switch_viewer("source_monitor")
fullscreen_viewer.exit()
print("  ok: enter→switch→exit without assertion (C++ mirror handoff clean)")

-- ── DR-11: ToggleFullscreenView command ───────────────────────────────────────
print("\n--- DR-11: ToggleFullscreenView command respects focus ---")
local toggle_cmd = require("core.commands.toggle_fullscreen_view")
local focus_manager = require("ui.focus_manager")
local reg = toggle_cmd.register({}, {}, nil)
assert(reg.executor, "ToggleFullscreenView must have executor")
assert(reg.spec.undoable == false, "ToggleFullscreenView must be non-undoable")

-- Timeline monitor focused → fullscreen that viewer.
focus_manager.set_focused_panel("timeline_monitor")
reg.executor({})
assert(fullscreen_viewer.is_active() == true,
    "command must enter fullscreen on first call")
assert(fullscreen_viewer.get_current_view_id() == "timeline_monitor",
    "command must fullscreen timeline_monitor when it has focus")

reg.executor({})
assert(fullscreen_viewer.is_active() == false,
    "command must exit fullscreen on second call (toggle)")

-- Source monitor focused → fullscreen that viewer.
focus_manager.set_focused_panel("source_monitor")
reg.executor({})
assert(fullscreen_viewer.is_active() == true)
assert(fullscreen_viewer.get_current_view_id() == "source_monitor",
    "command must fullscreen source_monitor when it has focus")
fullscreen_viewer.exit()

-- Non-viewer panel (project_browser) → defaults to timeline_monitor.
focus_manager.set_focused_panel("project_browser")
reg.executor({})
assert(fullscreen_viewer.is_active() == true)
assert(fullscreen_viewer.get_current_view_id() == "timeline_monitor",
    "non-viewer panel focus must default to timeline_monitor")
fullscreen_viewer.exit()
print("  ok")

-- ── DR-5: project_changed exits fullscreen ────────────────────────────────────
-- RUNS LAST: emitting project_changed causes transport.teardown_engine
-- (priority 5) to clear _playback_controller on all engines. Any enter()
-- call after this point would assert. DR-5 is terminal for this test.
print("\n--- DR-5: project_changed exits fullscreen (LAST — tears down transport) ---")
fullscreen_viewer.enter("timeline_monitor")
assert(fullscreen_viewer.is_active() == true, "precondition: active before signal")
Signals.emit("project_changed", "new_project_999")
assert(fullscreen_viewer.is_active() == false,
    "DR-5: project_changed must exit fullscreen (mirror left dangling crashes C++)")
assert(tl_mon._frame_mirror == nil,
    "DR-5: Lua mirror must be cleared on project_changed")
print("  ok")

print("\n✅ test_fullscreen_viewer.lua (integration) passed")
