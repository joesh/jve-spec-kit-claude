#!/usr/bin/env luajit

-- T008 (015) — SetSyncMode command contract (C3).
--
-- Domain: sync_mode is a per-track session preference that controls how a
-- track participates in ripple operations. Off/Ripple/Cut must be settable,
-- invalid values refused, changes not reverted by undo, signal emitted.
--
-- Expected FAIL today: SetSyncMode command does not exist AND tracks.sync_mode
-- column does not exist (migration not applied).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Signals = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_set_sync_mode.lua ===")

local DB = "/tmp/jve/test_set_sync_mode.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
-- New tracks default to sync_mode='ripple' (migration default).
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('trk', 'seq', 'A1', 'AUDIO', 1, 1)
]])

command_manager.init("seq", "proj")

local function get_sync_mode()
    local s = db:prepare("SELECT sync_mode FROM tracks WHERE id = 'trk'")
    assert(s, "tracks.sync_mode column missing — migration not applied")
    s:exec(); s:next(); local v = s:value(0); s:finalize(); return v
end

local signal_log = {}
Signals.connect("sync_mode_changed", function(tid, new_mode, prev_mode)
    table.insert(signal_log, {track_id=tid, new=new_mode, prev=prev_mode})
end)

-- ── Default is 'ripple' ───────────────────────────────────────────────────
print("-- default sync_mode --")
assert(get_sync_mode() == "ripple",
    "new track must default to sync_mode='ripple', got: " .. tostring(get_sync_mode()))
print("  default='ripple' — OK")

-- ── Set to 'off' ──────────────────────────────────────────────────────────
print("-- set to 'off' --")
local r1 = command_manager.execute("SetSyncMode", {
    track_id   = "trk",
    sync_mode  = "off",
    project_id = "proj",
})
assert(r1 and r1.success, "SetSyncMode off failed: " .. tostring(r1 and r1.error_message))
assert(get_sync_mode() == "off", "sync_mode must be 'off'")
print("  set to 'off' — OK")

-- signal emitted with correct payload
assert(#signal_log >= 1, "sync_mode_changed signal not emitted")
local sig = signal_log[#signal_log]
assert(sig.track_id == "trk", "signal track_id wrong")
assert(sig.new == "off", "signal new_mode wrong: " .. tostring(sig.new))
assert(sig.prev == "ripple", "signal prev_mode wrong: " .. tostring(sig.prev))
print("  signal payload correct — OK")

-- ── Set to 'cut' ──────────────────────────────────────────────────────────
print("-- set to 'cut' --")
local r2 = command_manager.execute("SetSyncMode", {
    track_id   = "trk",
    sync_mode  = "cut",
    project_id = "proj",
})
assert(r2 and r2.success, "SetSyncMode cut failed")
assert(get_sync_mode() == "cut", "sync_mode must be 'cut'")
print("  set to 'cut' — OK")

-- ── Back to 'ripple' ──────────────────────────────────────────────────────
local r3 = command_manager.execute("SetSyncMode", {
    track_id   = "trk",
    sync_mode  = "ripple",
    project_id = "proj",
})
assert(r3 and r3.success, "SetSyncMode ripple failed")
assert(get_sync_mode() == "ripple", "sync_mode must be 'ripple'")
print("  back to 'ripple' — OK")

-- ── Not on undo stack ─────────────────────────────────────────────────────
print("-- SetSyncMode is not undoable --")
command_manager.undo()
assert(get_sync_mode() == "ripple",
    "FAIL: SetSyncMode was reverted by undo — must be undoable=false")
print("  undo no-op — OK")

-- ── Invalid value refused ─────────────────────────────────────────────────
print("-- invalid sync_mode refused --")
local r_bad = command_manager.execute("SetSyncMode", {
    track_id   = "trk",
    sync_mode  = "banana",
    project_id = "proj",
})
assert(not (r_bad and r_bad.success),
    "SetSyncMode with 'banana' must fail (SQL CHECK + runtime assert)")
print("  invalid value refused — OK")

-- ── Nonexistent track_id asserts ──────────────────────────────────────────
print("-- nonexistent track asserts --")
local r_ghost = command_manager.execute("SetSyncMode", {
    track_id   = "no_such_track",
    sync_mode  = "off",
    project_id = "proj",
})
assert(not (r_ghost and r_ghost.success),
    "SetSyncMode on missing track must fail")
print("  missing track refused — OK")

print("\n✅ test_set_sync_mode.lua passed")
