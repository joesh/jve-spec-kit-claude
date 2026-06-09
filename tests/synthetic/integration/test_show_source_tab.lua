-- Integration (015 / T011): ShowSourceTab command contract.
--
-- Domain rules:
--   (a) source loaded → switch the strip's displayed tab to the source
--       master + emit source_tab_visibility_changed(true).
--   (b) source NOT loaded → blank the timeline body (timeline_state.clear);
--       do NOT auto-seed a master, do NOT fire visibility signal — the
--       user chose nothing, so the editor shows nothing. (TSO 2026-05-17:
--       the auto-seed-first-master path fabricated user intent.)
--   (c) re-open is idempotent — calling again with the same master still
--       succeeds and re-fires visibility(true).
--   (d) non-undoable: no snapshots row produced, undo is a no-op.
--   (e) asserts when panel_manager.source_monitor is unavailable.
--
-- Replaces the stub-heavy headless test of the same name. Runs under
-- JVEEditor --test with real SequenceMonitor + real tab strip; the
-- previous mock-based assertions ("switch_to_source_tab called with
-- src_master") are replaced by observable strip state.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_show_source_tab.lua ===")

require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local panel_manager   = require("ui.panel_manager")
local timeline_state  = require("ui.timeline.timeline_state")
local Signals         = require("core.signals")

-- ── DB setup ────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_show_source_tab_integration.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('proj','P','resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
              %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES
        ('rec_seq',    'proj', 'Timeline',   'sequence', 24,1,48000,1920,1080,
                       0, 0, 300, 0, %d, %d),
        ('src_master', 'proj', 'master_clip','master',   24,1,NULL, 1920,1080,
                       0, 0, 300, 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES ('rv1','rec_seq','V1','VIDEO',1,1);
]], now, now, now, now, now, now)))

command_manager.init("rec_seq", "proj")

-- Real monitors. source_monitor.sequence_id starts nil (no clip loaded).
local mons = ienv.setup_monitor_panels({ kinds = "both" })
local source_mon, timeline_mon = mons.source, mons.timeline

local strip = timeline_state.get_tab_strip()

-- Visibility-signal log captures every emission.
local vis_log = {}
Signals.connect("source_tab_visibility_changed", function(visible)
    vis_log[#vis_log + 1] = visible
end)

-- ── (a) source loaded → strip's displayed tab becomes the source ───────
print("-- (a) source loaded → strip displayed = source(src_master) --")
source_mon.sequence_id = "src_master"
local r1 = command_manager.execute("ShowSourceTab", {})
assert(r1 and r1.success,
    "ShowSourceTab must succeed: " .. tostring(r1 and r1.error_message))

local displayed = strip:get_displayed()
assert(displayed and displayed.kind == "source"
   and displayed.sequence_id == "src_master", string.format(
    "after ShowSourceTab, strip:get_displayed() must be source(src_master); "
    .. "got kind=%s sequence_id=%s",
    tostring(displayed and displayed.kind),
    tostring(displayed and displayed.sequence_id)))
assert(#vis_log >= 1 and vis_log[#vis_log] == true,
    "source_tab_visibility_changed(true) must fire after the source tab is shown")
print("  strip displayed = source(src_master), visibility(true) fired")

-- ── (b) no source loaded → blank displayed, no auto-seed, no signal ────
-- The contract here is "the editor shows nothing because the user chose
-- nothing." Observable: strip's displayed pointer goes nil, no new
-- visibility signal, and the source monitor was NOT auto-seeded with a
-- random master from the DB (TSO 2026-05-17 retired that path).
-- timeline_state.clear() does NOT destroy the strip's source-tab
-- singleton — that survives the displayed-pointer reset by design — so
-- we don't assert against get_source_tab() here.
print("-- (b) no source loaded → blank displayed, no auto-seed --")
source_mon.sequence_id = nil
local vis_before = #vis_log

local r2 = command_manager.execute("ShowSourceTab", {})
assert(r2 and r2.success, "ShowSourceTab must succeed even with no master")
assert(strip:get_displayed() == nil, string.format(
    "no-master ShowSourceTab must blank the strip's displayed pointer; "
    .. "got %s", tostring(strip:get_displayed())))
assert(#vis_log == vis_before, string.format(
    "no-master ShowSourceTab must NOT emit visibility(true) — nothing became "
    .. "visible. vis_log grew from %d to %d", vis_before, #vis_log))
-- source_mon.sequence_id stayed nil — i.e. no auto-seed happened.
assert(source_mon.sequence_id == nil,
    "no-master ShowSourceTab must NOT auto-load a master into the source monitor")
print("  displayed blanked, no auto-seed, no spurious visibility signal")

-- ── (c) idempotent re-open ─────────────────────────────────────────────
print("-- (c) re-open is idempotent --")
source_mon.sequence_id = "src_master"
local vis_before_c = #vis_log

local r3 = command_manager.execute("ShowSourceTab", {})
assert(r3 and r3.success, "second ShowSourceTab call must succeed")
local displayed_c = strip:get_displayed()
assert(displayed_c and displayed_c.kind == "source"
   and displayed_c.sequence_id == "src_master",
    "re-open must leave the strip displaying source(src_master)")
assert(#vis_log == vis_before_c + 1 and vis_log[#vis_log] == true,
    "re-open still emits visibility(true) — idempotent show")
print("  second call succeeds, visibility re-fires")

-- ── (d) non-undoable: no snapshot row, undo is a no-op ─────────────────
print("-- (d) non-undoable --")
local function count_snapshots()
    local s = db:prepare("SELECT COUNT(*) FROM snapshots")
    s:exec(); s:next()
    local n = s:value(0); s:finalize()
    return n
end

local snaps_before = count_snapshots()
command_manager.execute("ShowSourceTab", {})
assert(count_snapshots() == snaps_before, string.format(
    "ShowSourceTab must not create snapshot rows (before=%d after=%d)",
    snaps_before, count_snapshots()))

local vis_before_undo = #vis_log
command_manager.undo()
assert(#vis_log == vis_before_undo,
    "undo must not re-fire source_tab_visibility_changed — non-undoable")
print("  no snapshot row, undo is no-op")

-- ── (e) assert when panel_manager.source_monitor is absent ─────────────
print("-- (e) assert when source_monitor not registered --")
-- Re-register a registry without the source_monitor entry by re-creating
-- panel_manager's table via package.loaded reload would also drop the
-- timeline_monitor we need. Cleanest: unregister via the manager's API
-- when available; otherwise replace just the slot.
local saved = panel_manager.get_sequence_monitor("source_monitor")
package.loaded["ui.panel_manager"] = nil
local pm_reload = require("ui.panel_manager")
-- Only register the timeline side; leave source slot empty.
pm_reload.register_sequence_monitor("timeline_monitor", timeline_mon)

local r5 = command_manager.execute("ShowSourceTab", {})
assert(not (r5 and r5.success),
    "ShowSourceTab must report failure (or assert via command_manager) when "
    .. "source_monitor is not registered; got success=" .. tostring(r5 and r5.success))
-- Restore for any later listeners.
pm_reload.register_sequence_monitor("source_monitor", saved)
print("  missing source_monitor surfaces as command failure")

print("\nPASS test_show_source_tab.lua")
