-- Integration (015 T036): source_loaded_changed signal contract.
--
-- Scenarios:
--   (a) First load            → source_loaded_changed(new,  nil)
--   (b) Switch load           → source_loaded_changed(new,  prev)
--   (c) Reload same source    → source_loaded_changed(same, same)
--   (d) Unload                → source_loaded_changed(nil,  prev)  via M.unload()
--   (e) Unload when unloaded  → no signal (nothing changed)
--   (f) Nil arg               → asserts
--
-- Replaces the stub-based test of the same name. Uses real
-- SequenceMonitor + real DB-resident masters under JVEEditor --test.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_source_viewer_signal.lua ===")

require("test_env")

local database        = require("core.database")
local Signals         = require("core.signals")

-- ── DB: project + two master sequences ────────────────────────────────
local DB = "/tmp/jve/test_source_viewer_signal_integ.db"
os.execute("mkdir -p /tmp/jve")
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))

assert(db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
      VALUES ('test_project', 'P', 'resample',
              '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    -- A record sequence with audio_sample_rate so audio_bus_rate can
    -- resolve the output bus rate when loading a video-only master into
    -- the source monitor (FR-018 follow-on; SequenceMonitor:load_sequence
    -- asserts a valid bus rate exists for the project).
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, start_timecode_frame, created_at, modified_at)
      VALUES
        ('rec',      'test_project', 'Rec', 'sequence', 24, 1, 48000,
         1920, 1080, 0, 0, 300, 0, 0, 0),
        ('master_A', 'test_project', 'A',   'master',   24, 1, NULL,
         1920, 1080, 0, 0, 300, 0, 0, 0),
        ('master_B', 'test_project', 'B',   'master',   24, 1, NULL,
         1920, 1080, 0, 0, 300, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
      VALUES
        ('rv1',  'rec',      'V1', 'VIDEO', 1, 1),
        ('a_v1', 'master_A', 'V1', 'VIDEO', 1, 1),
        ('b_v1', 'master_B', 'V1', 'VIDEO', 1, 1);
]]))

-- Real source monitor + transport bootstrap. (timeline_monitor not
-- needed by this test; source_viewer.load_master_clip only reaches for
-- source_monitor. transport.init binds the source-role engine via the
-- transport_ready listener at sequence_monitor.lua:247.)
ienv.setup_monitor_panels({
    kinds = "source", transport_project_id = "test_project",
})

-- Force fresh load of source_viewer with our registered monitor.
package.loaded["ui.source_viewer"] = nil
local source_viewer = require("ui.source_viewer")

-- ── Signal log ────────────────────────────────────────────────────────
local signal_log = {}
Signals.connect("source_loaded_changed", function(new_id, prev_id)
    signal_log[#signal_log + 1] = { new = new_id, prev = prev_id }
end)

assert(type(source_viewer.unload) == "function",
    "source_viewer.unload must exist (015 T036)")

-- ── (a) First load: emits (new, nil) ─────────────────────────────────
print("-- (a) first load --")
local n0 = #signal_log
source_viewer.load_master_clip("master_A", { skip_focus = true })
assert(#signal_log == n0 + 1,
    "source_loaded_changed must fire on first load")
local ev = signal_log[#signal_log]
assert(ev.new == "master_A" and ev.prev == nil, string.format(
    "first load: (new, prev) must be (master_A, nil); got (%s, %s)",
    tostring(ev.new), tostring(ev.prev)))
print("  PASS source_loaded_changed(master_A, nil)")

-- ── (b) Switch load: emits (new, prev) ───────────────────────────────
print("-- (b) switch load --")
local n1 = #signal_log
source_viewer.load_master_clip("master_B", { skip_focus = true })
assert(#signal_log == n1 + 1, "signal must fire on switch")
ev = signal_log[#signal_log]
assert(ev.new == "master_B" and ev.prev == "master_A", string.format(
    "switch: (new, prev) must be (master_B, master_A); got (%s, %s)",
    tostring(ev.new), tostring(ev.prev)))
print("  PASS source_loaded_changed(master_B, master_A)")

-- ── (c) Reload same source: still fires (prev == new) ────────────────
print("-- (c) reload same source --")
local n2 = #signal_log
source_viewer.load_master_clip("master_B", { skip_focus = true })
assert(#signal_log == n2 + 1,
    "signal must fire even on reload of same source — listeners debounce")
ev = signal_log[#signal_log]
assert(ev.new == "master_B" and ev.prev == "master_B", string.format(
    "reload: (new, prev) must be (master_B, master_B); got (%s, %s)",
    tostring(ev.new), tostring(ev.prev)))
print("  PASS source_loaded_changed(master_B, master_B)")

-- ── (d) Unload: emits (nil, prev) ────────────────────────────────────
print("-- (d) unload --")
local n3 = #signal_log
source_viewer.unload()
assert(#signal_log == n3 + 1, "signal must fire on unload")
ev = signal_log[#signal_log]
assert(ev.new == nil and ev.prev == "master_B", string.format(
    "unload: (new, prev) must be (nil, master_B); got (%s, %s)",
    tostring(ev.new), tostring(ev.prev)))
print("  PASS source_loaded_changed(nil, master_B)")

-- ── (e) Unload when already unloaded: no signal ──────────────────────
print("-- (e) unload when already unloaded --")
local n4 = #signal_log
source_viewer.unload()
assert(#signal_log == n4,
    "no signal when unloading an already-unloaded source")
print("  PASS no signal on redundant unload")

-- ── (f) Nil arg asserts ──────────────────────────────────────────────
print("-- (f) nil arg --")
local ok = pcall(source_viewer.load_master_clip, nil, { skip_focus = true })
assert(not ok, "load_master_clip(nil) must assert")
print("  PASS nil arg asserts")

print("\nPASS test_source_viewer_signal.lua")
