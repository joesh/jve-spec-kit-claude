-- Integration test: F-press across media types does NOT leave a ghost
-- source tab behind.
--
-- Domain bug (TSO 2026-05-23, verified by Joe 2026-05-24): with master
-- A loaded in the source viewer, F-pressing on a clip whose master is
-- B used to leave the panel showing the A tab AND a new B tab — A
-- stuck around as a "rec-like" ghost. The strip-side singleton had
-- reloaded in place, but the Lua-side open_tabs (keyed by sequence_id)
-- created a fresh container under key B without removing the entry
-- under key A.
--
-- Invariant: open_tabs[X].strip_tab.sequence_id == X.
--   • Single source-tab panel entry at any time.
--   • Key always matches the strip-side seq, mirroring the strip's
--     source-singleton reload-in-place semantics.
--
-- Runs under JVEEditor --test (real C++ bindings, real Qt widgets, no
-- main window — we instantiate the panel + monitor directly).
--
-- NSF: every fixture call is checked; no fallbacks; assertion failure
-- on any drift surfaces loudly.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_source_tab_rekey_no_orphan.lua ===")

require("test_env")
local database         = require("core.database")
local Signals          = require("core.signals")
local timeline_state   = require("ui.timeline.timeline_state")

-- ----------------------------------------------------------------------
-- Project DB: record sequence R + two masters M_A, M_B.
-- ----------------------------------------------------------------------
local DB = "/tmp/jve/test_source_tab_rekey.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('p','P','passthrough',
              '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES
        ('R',  'p','Record', 'sequence',24,1,48000,1920,1080,0,0,1000,0,%d,%d),
        ('MA', 'p','A.mov',  'master',  24,1,NULL, 1920,1080,0,0,1000,0,%d,%d),
        ('MB', 'p','B.mov',  'master',  24,1,NULL, 1920,1080,0,0,1000,0,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES
        ('rv1','R', 'V1','VIDEO',1,1), ('ra1','R', 'A1','AUDIO',1,1),
        ('av1','MA','V1','VIDEO',1,1), ('aa1','MA','A1','AUDIO',1,1),
        ('bv1','MB','V1','VIDEO',1,1), ('ba1','MB','A1','AUDIO',1,1);
]], now, now, now, now, now, now, now, now)))

-- ----------------------------------------------------------------------
-- Register source_monitor + timeline_monitor BEFORE timeline_panel.create
-- (the panel reads source_monitor.get_loaded_master_seq_id() during
-- ensure_tab_for_sequence to classify source vs record requests).
-- ----------------------------------------------------------------------
local mons = ienv.setup_monitor_panels({ kinds = "both" })
local source_monitor, timeline_monitor = mons.source, mons.timeline

-- ----------------------------------------------------------------------
-- Bring up the panel. project_id required; sequence_id seeds the active
-- record. No main window — the panel widgets just live free-standing.
-- ----------------------------------------------------------------------
local timeline_panel_mod = require("ui.timeline.timeline_panel")
local panel_widget = timeline_panel_mod.create({ project_id = "p", sequence_id = "R" })
assert(panel_widget, "timeline_panel.create returned nil")

-- ----------------------------------------------------------------------
-- Open the source tab for MA programmatically — simulates the
-- project-restore path where the panel reconstructs persisted tabs
-- from the project DB without routing through source_loaded_changed.
-- The pre-fix bug surfaced specifically in this path because the
-- auto_source_tab_id close-on-prev heuristic only tracked tabs that
-- the source_loaded_changed listener auto-opened; persisted-restored
-- source tabs left auto_source_tab_id == nil, so the subsequent
-- F-press swap's eviction check was skipped and the orphan persisted.
-- ----------------------------------------------------------------------
source_monitor.sequence_id = "MA"
timeline_panel_mod.open_tab("MA")

local source_seq = timeline_panel_mod._test_get_source_tab_seq_id()
assert(source_seq == "MA", string.format(
    "after loading MA, source tab should be MA; got %s", tostring(source_seq)))

local tabs = timeline_panel_mod.get_open_tab_ids()
local function tabs_set(list)
    local s = {}
    for _, id in ipairs(list) do s[id] = true end
    return s
end
local s1 = tabs_set(tabs)
assert(s1["R"] and s1["MA"] and not s1["MB"], string.format(
    "open tabs after MA load should be {R, MA}; got %s", table.concat(tabs, ",")))
print(string.format("  PASS: source loaded MA → open_tabs = {R, MA}"))

-- ----------------------------------------------------------------------
-- F-press across media types: source moves MA → MB. The bug was that
-- this left MA behind. The fix is rekey-in-place: open_tabs[MA] is
-- moved to open_tabs[MB] in the same widget container.
-- ----------------------------------------------------------------------
source_monitor.sequence_id = "MB"
Signals.emit("source_loaded_changed", "MB", "MA")

source_seq = timeline_panel_mod._test_get_source_tab_seq_id()
assert(source_seq == "MB", string.format(
    "after MA→MB source swap, source tab should be MB; got %s",
    tostring(source_seq)))

tabs = timeline_panel_mod.get_open_tab_ids()
local s2 = tabs_set(tabs)
assert(s2["R"] and s2["MB"], string.format(
    "open tabs after MA→MB should include {R, MB}; got %s",
    table.concat(tabs, ",")))
assert(not s2["MA"], string.format(
    "ORPHAN BUG: MA tab persisted after source moved to MB. open_tabs = %s",
    table.concat(tabs, ",")))
print("  PASS: source MA → MB rekeyed; MA tab gone, MB present")

-- ----------------------------------------------------------------------
-- Source-clear path: source_viewer.unload emits (nil, prev). The source
-- tab must be dropped to maintain the invariant.
-- ----------------------------------------------------------------------
source_monitor.sequence_id = nil
Signals.emit("source_loaded_changed", nil, "MB")

source_seq = timeline_panel_mod._test_get_source_tab_seq_id()
assert(source_seq == nil, string.format(
    "after source clear, source_tab_seq_id should be nil; got %s",
    tostring(source_seq)))

tabs = timeline_panel_mod.get_open_tab_ids()
local s3 = tabs_set(tabs)
assert(s3["R"] and not s3["MA"] and not s3["MB"], string.format(
    "open tabs after source clear should be {R}; got %s",
    table.concat(tabs, ",")))
print("  PASS: source cleared → source tab dropped, R remains")

print("\nPASS test_source_tab_rekey_no_orphan.lua")
