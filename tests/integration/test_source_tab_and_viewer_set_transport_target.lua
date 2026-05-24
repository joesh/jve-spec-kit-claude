-- Integration (017): pressing Space while the source viewer or source
-- tab is displayed must route transport to the SOURCE side, not record.
--
-- Domain rules:
--   switch_to_source_tab(seq) → transport.get_target() == "source"
--   source_viewer.load_master_clip → focuses source_monitor → derived
--     target resolves to "source"
--   After load_master_clip, the source-role engine carries the loaded
--     master so TogglePlay drives the source side; the record engine
--     does NOT mirror it.
--
-- Replaces the stub-heavy headless test of the same name. Runs under
-- JVEEditor --test with real SequenceMonitor + real transport.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_source_tab_and_viewer_set_transport_target.lua ===")

require("test_env")

local database        = require("core.database")
local SequenceMonitor = require("ui.sequence_monitor")
local panel_manager   = require("ui.panel_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local transport       = require("core.playback.transport")
local source_viewer   = require("ui.source_viewer")

-- ── DB: project + record sequence "rec" + master sequence "src" ────────
local DB = "/tmp/jve/test_source_tab_transport_target_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES
        ('rec', 'p', 'Rec',       'sequence', 24, 1, 48000, 1920, 1080,
         0, 0, 300, 0, %d, %d),
        ('src', 'p', 'SrcMaster', 'master',   24, 1, NULL,  1920, 1080,
         0, 0, 300, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('rv1', 'rec', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now, now, now)))

-- Real monitors + real transport bootstrap. Layout normally
-- registers each monitor's widget with focus_manager so focus_panel
-- works; --test doesn't run layout, so we register inline. Without
-- this, source_viewer.load_master_clip's focus_panel("source_monitor")
-- call would warn-and-return and transport.get_target() would never
-- derive to "source".
local focus_manager = require("ui.focus_manager")
local source_mon   = SequenceMonitor.new({ view_id = "source_monitor"   })
local timeline_mon = SequenceMonitor.new({ view_id = "timeline_monitor" })
panel_manager.register_sequence_monitor("source_monitor",   source_mon)
panel_manager.register_sequence_monitor("timeline_monitor", timeline_mon)
focus_manager.register_panel("source_monitor",   source_mon:get_widget(),
    source_mon:get_title_widget(),   "Source")
focus_manager.register_panel("timeline_monitor", timeline_mon:get_widget(),
    timeline_mon:get_title_widget(), "Timeline")

transport.init("p")
local src_engine = transport.engine_for_role("source")
local rec_engine = transport.engine_for_role("record")

-- ── Default: no source signal yet → target derives to "record" ────────
assert(transport.get_target() == "record", string.format(
    "fresh state: no source loaded → derived target 'record'; got '%s'",
    transport.get_target()))
print("  PASS fresh target = 'record'")

-- ── source-tab click → displayed_tab_kind = source → target = source ──
timeline_state.switch_to_source_tab("src")
assert(transport.get_target() == "source", string.format(
    "switch_to_source_tab('src') → displayed_tab_kind=source → target 'source'; got '%s'",
    transport.get_target()))
print("  PASS switch_to_source_tab → target = 'source'")

-- ── Flip back to record so we can prove the viewer path separately ────
timeline_state.switch_to_record_tab("rec")
assert(transport.get_target() == "record", string.format(
    "switch_to_record_tab('rec') → target 'record'; got '%s'",
    transport.get_target()))
print("  PASS switch_to_record_tab → target = 'record'")

-- ── source_viewer.load_master_clip → focus source_monitor → target = source ──
-- Real call (no skip_focus): focus_manager moves to source_monitor →
-- derived target resolves to "source". The source engine binds to the
-- loaded master; record engine must NOT mirror it.
source_viewer.load_master_clip("src")

assert(transport.get_target() == "source", string.format(
    "source_viewer.load_master_clip must focus source_monitor → target 'source'; got '%s'",
    transport.get_target()))
print("  PASS load_master_clip → target = 'source'")

assert(src_engine.loaded_sequence_id == "src", string.format(
    "source engine must carry the loaded master 'src' after load_master_clip; "
    .. "got loaded_sequence_id=%s", tostring(src_engine.loaded_sequence_id)))
assert(rec_engine.loaded_sequence_id ~= "src",
    "record engine must NOT mirror the source master")
print("  PASS source engine bound to 'src'; record engine independent")

print("\nPASS test_source_tab_and_viewer_set_transport_target.lua")
