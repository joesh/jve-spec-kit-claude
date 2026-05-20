#!/usr/bin/env luajit

-- T036 (015) — source_loaded_changed signal contract.
--
-- Domain: when the source monitor loads or unloads a master sequence, the
-- `source_loaded_changed` signal must fire with (new_master_seq_id, prev_master_seq_id).
-- Callers (timeline_panel tab-strip, status bar, etc.) listen to this signal to
-- refresh their display without polling.
--
-- Scenarios:
--   (a) First load:  source_loaded_changed(new_seq, nil)
--   (b) Switch load: source_loaded_changed(new_seq, prev_seq)
--   (c) Unload:      source_loaded_changed(nil, prev_seq)  [via M.unload()]
--
-- Panel-manager and focus-manager are stubbed via package.preload so the test
-- runs without Qt bindings.
--
-- Expected FAIL today: source_viewer does not emit source_loaded_changed.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local Signals = require("core.signals")

-- ── Stubs: replace panel_manager and focus_manager before requiring ───────
-- source_viewer requires both lazily inside functions, so overriding
-- package.loaded BEFORE the first call is sufficient.

local mock_monitor = {
    sequence_id = nil,
    sequence    = nil,
    load_calls  = {},
}
function mock_monitor:load_sequence(seq_id)
    self.sequence_id = seq_id
    -- Mirror real SequenceMonitor:load_sequence — it stores the loaded
    -- Sequence model on `.sequence`. This test isolates the signal
    -- contract from the DB, so the stub fabricates the minimal record
    -- source_viewer reads: id + project_id.
    self.sequence = { id = seq_id, project_id = "test_project" }
    table.insert(self.load_calls, seq_id)
end
function mock_monitor:get_loaded_master_seq_id()
    return self.sequence_id
end
function mock_monitor:unload()
    self.sequence_id = nil
    self.sequence = nil
end
-- Mirror real SequenceMonitor:_set_title (sequence_monitor.lua:1036).
function mock_monitor:_set_title(text) self.title = text end

package.loaded["ui.panel_manager"] = {
    get_sequence_monitor = function(view_id)
        assert(view_id == "source_monitor",
            "stub: unexpected view_id " .. tostring(view_id))
        return mock_monitor
    end,
}
package.loaded["ui.focus_manager"] = {
    focus_panel = function() end,  -- no-op stub
}

-- Force fresh load of source_viewer (in case it was cached without our stubs).
package.loaded["ui.source_viewer"] = nil
local source_viewer = require("ui.source_viewer")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_source_viewer_signal.lua ===")

-- ── Signal log ────────────────────────────────────────────────────────────
local signal_log = {}
Signals.connect("source_loaded_changed", function(new_id, prev_id)
    table.insert(signal_log, {new=new_id, prev=prev_id})
end)

-- ── Verify M.unload exists ────────────────────────────────────────────────
assert(type(source_viewer.unload) == "function",
    "FAIL: source_viewer.unload missing — T036 not implemented")

-- ── (a) First load: emits (new, nil) ─────────────────────────────────────
print("-- (a) first load --")
local n0 = #signal_log
source_viewer.load_master_clip("master_A", {skip_focus=true})

assert(#signal_log == n0 + 1,
    "FAIL: source_loaded_changed not emitted on first load")
local ev1 = signal_log[#signal_log]
assert(ev1.new == "master_A", string.format(
    "FAIL: signal new=%s, expected master_A", tostring(ev1.new)))
assert(ev1.prev == nil, string.format(
    "FAIL: signal prev=%s, expected nil on first load", tostring(ev1.prev)))
print("  source_loaded_changed(master_A, nil) — OK")

-- ── (b) Switch load: emits (new, prev) ───────────────────────────────────
print("-- (b) switch load --")
local n1 = #signal_log
source_viewer.load_master_clip("master_B", {skip_focus=true})

assert(#signal_log == n1 + 1,
    "FAIL: source_loaded_changed not emitted on source switch")
local ev2 = signal_log[#signal_log]
assert(ev2.new == "master_B", string.format(
    "FAIL: signal new=%s, expected master_B", tostring(ev2.new)))
assert(ev2.prev == "master_A", string.format(
    "FAIL: signal prev=%s, expected master_A", tostring(ev2.prev)))
print("  source_loaded_changed(master_B, master_A) — OK")

-- ── (c) Reload same source: still emits (idempotent caller must handle it) ─
-- The contract does NOT require suppression of same-reload — callers debounce
-- if needed. But the signal MUST fire so listeners are notified.
print("-- (c) reload same source --")
local n2 = #signal_log
source_viewer.load_master_clip("master_B", {skip_focus=true})

assert(#signal_log == n2 + 1,
    "FAIL: source_loaded_changed must fire even on reload of same source (prev==new is valid)")
local ev3 = signal_log[#signal_log]
assert(ev3.new == "master_B" and ev3.prev == "master_B", string.format(
    "FAIL: same-reload payload wrong — new=%s prev=%s",
    tostring(ev3.new), tostring(ev3.prev)))
print("  source_loaded_changed(master_B, master_B) — OK")

-- ── (d) Unload: emits (nil, prev) ────────────────────────────────────────
print("-- (d) unload --")
local n3 = #signal_log
source_viewer.unload()

assert(#signal_log == n3 + 1,
    "FAIL: source_loaded_changed not emitted on unload")
local ev4 = signal_log[#signal_log]
assert(ev4.new == nil, string.format(
    "FAIL: signal new=%s, expected nil on unload", tostring(ev4.new)))
assert(ev4.prev == "master_B", string.format(
    "FAIL: signal prev=%s, expected master_B", tostring(ev4.prev)))
print("  source_loaded_changed(nil, master_B) — OK")

-- ── (e) Unload when nothing loaded: no signal (nothing changed) ───────────
print("-- (e) unload when already unloaded --")
local n4 = #signal_log
source_viewer.unload()

assert(#signal_log == n4,
    "FAIL: source_loaded_changed must NOT fire when unloading an already-unloaded source")
print("  no signal when already unloaded — OK")

-- ── (f) Assert guard on nil arg ───────────────────────────────────────────
print("-- (f) nil arg guard --")
local ok = pcall(source_viewer.load_master_clip, nil, {skip_focus=true})
assert(not ok, "FAIL: load_master_clip(nil) must assert")
print("  nil arg asserted — OK")

print("\n✅ test_source_viewer_signal.lua passed")
