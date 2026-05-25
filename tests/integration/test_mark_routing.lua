-- Integration: SetMark writes to the focused side's sequence (017 routing).
--
-- Regression: pressing I with the source side focused once set mark on the
-- timeline sequence (active_sequence_id) instead of the master being viewed.
-- 017 spec: SetMark's destination is transport.engine_for_target()'s loaded
-- sequence, which derives from focus_manager + displayed-tab kind.
--
-- Replaces the hand-rolled-engine mock test. Uses real transport, real
-- focus_manager, real PlaybackEngines bound to actual DB sequences. The
-- only thing this test stubs is the position on each engine — set via the
-- engine's public set_position() so no per-clip seek machinery is needed.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_mark_routing.lua ===")

require("test_env")
local database        = require("core.database")
local command_manager = require("core.command_manager")
local Sequence        = require("models.sequence")
local focus_manager   = require("ui.focus_manager")
local transport       = require("core.playback.transport")

-- ── DB: project + timeline_seq (record) + masterclip_seq (master) ────
local DB = "/tmp/jve/test_mark_routing_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
        created_at, modified_at)
      VALUES ('proj', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('timeline_seq',   'proj', 'Timeline',    'sequence', 30, 1, 48000, 1920, 1080,
              0, 0, 300, '[]', '[]', '[]', 0, 0, %d, %d),
             ('masterclip_seq', 'proj', 'Source Clip', 'master',   24, 1, NULL,  1920, 1080,
              0, 0, 300, '[]', '[]', '[]', 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now, now, now)))

-- Real monitors + focus wiring. command_manager.init below bootstraps
-- transport (its pcall'd transport.init), so we don't pass
-- transport_project_id here — would double-init and assert.
ienv.setup_monitor_panels({ kinds = "both", focus = "source_monitor" })

command_manager.init("timeline_seq", "proj")
command_manager.activate_timeline_stack("timeline_seq")
while pcall(command_manager.end_command_event) do end

-- Bind the source engine to the masterclip sequence so engine_for_target()
-- can route to it when source is focused.
transport.bind_role_to_sequence("source", "masterclip_seq")
transport.bind_role_to_sequence("record", "timeline_seq")

-- Distinct positions so we can prove the mark came from the right engine.
transport.source_engine:set_position(42)
transport.record_engine:set_position(10)

-- ── Test 1: source focused → SetMark writes masterclip ────────────────
print("-- (1) source focused → mark goes to masterclip --")
local r1 = command_manager.execute_interactive("SetMark", { _positional = {"in"} })
assert(r1 and r1.success, "SetMark must succeed: "
    .. tostring(r1 and r1.error_message))

local master_1   = Sequence.load("masterclip_seq")
local timeline_1 = Sequence.load("timeline_seq")
assert(master_1.mark_in == 42, string.format(
    "ROUTING BUG: source-focused SetMark must write masterclip.mark_in=42; "
    .. "got %s", tostring(master_1.mark_in)))
assert(timeline_1.mark_in == nil, string.format(
    "ROUTING BUG: source-focused SetMark must NOT touch timeline.mark_in; "
    .. "got %s", tostring(timeline_1.mark_in)))
print("  PASS masterclip.mark_in=42, timeline.mark_in=nil")

-- ── Test 2: record focused → SetMark writes timeline ──────────────────
-- Undo first so masterclip's mark_in returns to nil and the second SetMark
-- starts from clean state on both sequences.
print("-- (2) record focused → mark goes to timeline --")
command_manager.undo()
focus_manager.set_focused_panel("timeline_monitor")

local r2 = command_manager.execute_interactive("SetMark", { _positional = {"in"} })
assert(r2 and r2.success, "SetMark must succeed: "
    .. tostring(r2 and r2.error_message))

local master_2   = Sequence.load("masterclip_seq")
local timeline_2 = Sequence.load("timeline_seq")
assert(timeline_2.mark_in == 10, string.format(
    "ROUTING BUG: record-focused SetMark must write timeline.mark_in=10; "
    .. "got %s", tostring(timeline_2.mark_in)))
assert(master_2.mark_in == nil, string.format(
    "ROUTING BUG: record-focused SetMark must NOT touch masterclip "
    .. "(was restored to nil by undo); got %s", tostring(master_2.mark_in)))
print("  PASS timeline.mark_in=10, masterclip.mark_in=nil")

print("\nPASS test_mark_routing.lua")
