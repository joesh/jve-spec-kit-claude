-- Integration: transport target routing follows the displayed tab kind.
--
-- The 017 spec derives transport.get_target() from two inputs:
--   1. focus_manager.get_focused_panel() == "source_monitor"  → "source"
--   2. timeline_state.get_displayed_tab_kind() == "source"    → "source"
--   else                                                       → "record"
--
-- TogglePlay then calls transport.engine_for_target() to pick which engine
-- to drive. The original 2026-05-13 bug was that pressing Space while the
-- source tab was displayed played the record-bonded engine instead of the
-- master one.
--
-- Replaces the mock-engine test. Verifies routing via the public derived
-- API (transport.engine_for_target) rather than spying on which fake .play()
-- got called — same observation, no hand-rolled engine stubs.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_playback_routes_to_displayed_tab.lua ===")

require("test_env")
local database       = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")
local transport      = require("core.playback.transport")

-- ── DB: project + master + record sequence ───────────────────────────
local DB = "/tmp/jve/test_playback_routes_displayed_integ.db"
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
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame, view_duration_frames,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, start_timecode_frame, created_at, modified_at)
      VALUES ('rec', 'proj', 'Rec',       'sequence', 24, 1, 48000, 1920, 1080,
              0, 0, 300, '[]', '[]', '[]', 0, 0, %d, %d),
             ('src', 'proj', 'SrcMaster', 'master',   24, 1, NULL,  1920, 1080,
              0, 0, 300, '[]', '[]', '[]', 0, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('rec_v1', 'rec', 'V1', 'VIDEO', 1, 1),
             ('src_v1', 'src', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now, now, now)))

-- Real monitors + transport.init wires the source/record engines.
-- focus = "timeline_monitor" so the only routing signal is the displayed
-- tab kind (not source-monitor focus, which would short-circuit).
ienv.setup_monitor_panels({
    kinds = "both", focus = "timeline_monitor", transport_project_id = "proj",
})

-- Activate the record sequence so timeline_state has an active edit target.
timeline_state.init("rec", "proj")

local src_engine = transport.source_engine
local rec_engine = transport.record_engine
assert(src_engine and rec_engine,
    "transport.init must create both source and record engines")

-- ── (A) Source tab displayed → engine_for_target == source_engine ────
print("-- (a) source tab displayed --")
timeline_state.switch_to_source_tab("src")
assert(timeline_state.get_displayed_tab_kind() == "source",
    "fixture: switch_to_source_tab must set displayed kind to 'source'")
assert(transport.get_target() == "source", string.format(
    "source tab displayed → target='source'; got '%s'",
    transport.get_target()))
assert(transport.engine_for_target() == src_engine,
    "source tab displayed → engine_for_target must be source_engine")
print("  PASS routing to source_engine")

-- ── (B) Record tab displayed → engine_for_target == record_engine ────
print("-- (b) record tab displayed --")
timeline_state.switch_to_record_tab("rec")
assert(timeline_state.get_displayed_tab_kind() == "record",
    "fixture: switch_to_record_tab must set displayed kind to 'record'")
assert(transport.get_target() == "record", string.format(
    "record tab displayed → target='record'; got '%s'",
    transport.get_target()))
assert(transport.engine_for_target() == rec_engine,
    "record tab displayed → engine_for_target must be record_engine")
print("  PASS routing to record_engine")

print("\nPASS test_playback_routes_to_displayed_tab.lua")
