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

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_source_tab_and_viewer_set_transport_target.lua ===")

require("test_env")

local database        = require("core.database")
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

-- Real monitors + focus registration + real transport. focus_manager.
-- register_panel is required so source_viewer.load_master_clip's
-- focus_panel("source_monitor") doesn't warn-and-return — without it
-- transport.get_target() could never flip to "source". timeline_monitor
-- as initial focus matches layout.lua's startup default; get_target()
-- only flips to "source" on source_monitor focus or source-tab display,
-- so the timeline default is equivalent to "no focus" for this test.
ienv.setup_monitor_panels({
    kinds = "both", focus = "timeline_monitor", transport_project_id = "p",
})
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
