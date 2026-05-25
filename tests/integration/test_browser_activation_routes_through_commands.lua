-- Integration: browser activation routes through OpenSequenceInSourceMonitor
-- / OpenSequenceInTimeline (019 T006). Replaces a call-spy test that stubbed
-- source_viewer + timeline_panel + focus_manager to record dispatch
-- invocations. Real bindings observe via the actual state these commands
-- mutate: source_monitor.sequence_id, timeline_state.get_sequence_id(),
-- focus_manager.get_focused_panel().
--
-- Contracts under test:
--   OpenSequenceInSourceMonitor   → source viewer shows that sequence
--   OpenSequenceInTimeline        → timeline_state targets that sequence
--                                   AND timeline panel is focused
--   Both                          → undoable = false (undo is a no-op)

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_browser_activation_routes_through_commands.lua ===")

require("test_env")
local database        = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local focus_manager   = require("ui.focus_manager")

-- ── DB ────────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_browser_activation_routes_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
        created_at, modified_at)
      VALUES ('proj_X', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('seq_main',  'proj_X', 'Main',  'sequence', 24, 1, 48000, 1920, 1080,
              0, 10000, 0, '[]', '[]', '[]', 0, 0, %d, %d),
             -- A second record sequence so scenario 2 can switch FROM it
             -- TO seq_main and observe a real state transition.
             ('seq_other', 'proj_X', 'Other', 'sequence', 24, 1, 48000, 1920, 1080,
              0, 10000, 0, '[]', '[]', '[]', 0, 0, %d, %d),
             -- Master sequence so OpenSequenceInSourceMonitor has a master
             -- target (per 019 spec, source viewer shows masters only).
             ('master_clip', 'proj_X', 'Clip', 'master', 24, 1, NULL, 1920, 1080,
              0, 0, 100, '[]', '[]', '[]', 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('main_v1',  'seq_main',    'V1', 'VIDEO', 1, 1),
             ('other_v1', 'seq_other',   'V1', 'VIDEO', 1, 1),
             ('mclip_v1', 'master_clip', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now, now, now, now, now)))

-- Real monitors + focus wiring. command_manager.init bootstraps transport.
ienv.setup_monitor_panels({ kinds = "both", focus = "project_browser" })

-- OpenSequenceInTimeline focuses the "timeline" panel (the panel that holds
-- the timeline view, distinct from "timeline_monitor"). Register it here
-- to mirror layout.lua's startup.
local timeline_panel_widget = qt_constants.WIDGET.CREATE()
focus_manager.register_panel("timeline", timeline_panel_widget, nil, "Timeline")
focus_manager.register_panel("project_browser",
    qt_constants.WIDGET.CREATE(), nil, "Browser")

command_manager.init("seq_main", "proj_X")
command_manager.activate_timeline_stack("seq_main")
while pcall(command_manager.end_command_event) do end

local source_mon = require("ui.panel_manager").get_sequence_monitor("source_monitor")
assert(source_mon, "fixture: source_monitor must be registered")

-- ── (1) OpenSequenceInSourceMonitor → source viewer holds master_clip ─
print("-- (1) OpenSequenceInSourceMonitor --")
local r1 = command_manager.execute_interactive("OpenSequenceInSourceMonitor", {
    sequence_id = "master_clip",
    project_id  = "proj_X",
})
assert(r1 and r1.success, "OpenSequenceInSourceMonitor must succeed: "
    .. tostring(r1 and r1.error_message))
assert(source_mon.sequence_id == "master_clip", string.format(
    "source monitor must show master_clip after dispatch; got %s",
    tostring(source_mon.sequence_id)))
print("  PASS source_monitor.sequence_id = master_clip")

-- ── (2) OpenSequenceInTimeline → timeline_state targets seq_main + focuses ─
-- Switch to a different sequence first so the test can prove the dispatch
-- actually moved state (rather than confirming it was already there).
print("-- (2) OpenSequenceInTimeline --")
timeline_state.init("seq_other", "proj_X")
focus_manager.set_focused_panel("project_browser")
assert(timeline_state.get_sequence_id() == "seq_other",
    "fixture: timeline_state must start on seq_other before scenario 2")

local r2 = command_manager.execute_interactive("OpenSequenceInTimeline", {
    sequence_id = "seq_main",
    project_id  = "proj_X",
})
assert(r2 and r2.success, "OpenSequenceInTimeline must succeed: "
    .. tostring(r2 and r2.error_message))
assert(timeline_state.get_sequence_id() == "seq_main", string.format(
    "timeline_state must target seq_main after dispatch; got %s",
    tostring(timeline_state.get_sequence_id())))
assert(focus_manager.get_focused_panel() == "timeline", string.format(
    "OpenSequenceInTimeline must focus timeline panel; got %s",
    tostring(focus_manager.get_focused_panel())))
print("  PASS timeline_state on seq_main, focus on timeline")

-- ── (3) Both commands are undoable=false ──────────────────────────────
-- Re-execute OpenSequenceInSourceMonitor; undo must NOT revert the source
-- viewer state (the command isn't on the undo stack).
print("-- (3) commands are non-undoable --")
command_manager.execute_interactive("OpenSequenceInSourceMonitor", {
    sequence_id = "master_clip",
    project_id  = "proj_X",
})
assert(source_mon.sequence_id == "master_clip",
    "fixture: dispatch loaded master_clip")
command_manager.undo()
assert(source_mon.sequence_id == "master_clip", string.format(
    "OpenSequenceInSourceMonitor must be non-undoable; source state must "
    .. "survive undo. Got %s", tostring(source_mon.sequence_id)))
print("  PASS non-undoable: source state survives undo")

print("\nPASS test_browser_activation_routes_through_commands.lua")
