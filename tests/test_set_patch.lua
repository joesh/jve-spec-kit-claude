#!/usr/bin/env luajit

-- T007 (015) — SetPatch command contract (C2).
--
-- Domain: a patch is a per-track src→rec routing persisted on the sequence.
-- SetPatch must: create-on-first-touch, update fields, enforce UNIQUE,
-- refuse cross-track-type, not land on undo stack, emit patch_changed.
-- With enabled=0, Insert/Overwrite must succeed but NOT route that channel.
--
-- Expected FAIL today: SetPatch command does not exist.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Signals = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_set_patch.lua ===")

local DB = "/tmp/jve/test_set_patch.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'nested', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('trk_v1', 'seq', 'V1', 'VIDEO', 1, 1),
           ('trk_a1', 'seq', 'A1', 'AUDIO', 1, 1)
]])

command_manager.init("seq", "proj")

-- ── Helper ────────────────────────────────────────────────────────────────
local function patch_row(seq_id, src_idx)
    local s = db:prepare(
        "SELECT id, record_track_index, enabled FROM patches "
        .. "WHERE sequence_id=? AND source_track_index=?")
    assert(s)
    s:bind_value(1, seq_id); s:bind_value(2, src_idx)
    s:exec()
    if not s:next() then s:finalize(); return nil end
    local r = {id=s:value(0), rec=s:value(1), enabled=s:value(2)}
    s:finalize(); return r
end

local signal_payloads = {}
Signals.connect("patch_changed", function(seq_id, src_idx, change_type)
    table.insert(signal_payloads, {seq_id=seq_id, src_idx=src_idx, change_type=change_type})
end)

-- ── Create on first touch ─────────────────────────────────────────────────
print("-- create on first touch --")
local r1 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 0,
    record_track_index = 0,
    project_id         = "proj",
})
assert(r1 and r1.success, "SetPatch create failed: " .. tostring(r1 and r1.error_message))
local p1 = patch_row("seq", 0)
assert(p1, "patch row must exist after first SetPatch")
assert(p1.rec == 0, "record_track_index must be 0")
assert(p1.enabled == 1, "new patch must default to enabled=1")
print("  created: rec=0 enabled=1 — OK")

-- ── signal emitted ────────────────────────────────────────────────────────
assert(#signal_payloads >= 1, "patch_changed signal not emitted")
local sig = signal_payloads[#signal_payloads]
assert(sig.seq_id == "seq" and sig.src_idx == 0,
    "patch_changed payload wrong: " .. sig.seq_id .. "/" .. tostring(sig.src_idx))
assert(sig.change_type == "created" or sig.change_type == "updated",
    "patch_changed change_type unexpected: " .. tostring(sig.change_type))
print("  signal patch_changed emitted — OK")

-- ── Update record_track_index ─────────────────────────────────────────────
print("-- update record_track_index --")
local r2 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 0,
    record_track_index = 3,
    project_id         = "proj",
})
assert(r2 and r2.success, "SetPatch update failed: " .. tostring(r2 and r2.error_message))
local p2 = patch_row("seq", 0)
assert(p2 and p2.rec == 3, "record_track_index must be 3 after update")
print("  updated rec=3 — OK")

-- ── Update enabled=0 ─────────────────────────────────────────────────────
print("-- disable patch --")
local r3 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 0,
    enabled            = 0,
    project_id         = "proj",
})
assert(r3 and r3.success, "SetPatch disable failed")
local p3 = patch_row("seq", 0)
assert(p3 and p3.enabled == 0, "patch must be disabled")
print("  disabled — OK")

-- ── Not on undo stack ─────────────────────────────────────────────────────
print("-- SetPatch is not undoable --")
command_manager.undo()
local p_after_undo = patch_row("seq", 0)
assert(p_after_undo and p_after_undo.enabled == 0,
    "FAIL: SetPatch was reverted by undo — must be undoable=false")
print("  undo did not revert — OK")

-- ── Second patch — different source_track_index ───────────────────────────
print("-- second patch on same sequence --")
local r4 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 1,
    record_track_index = 1,
    project_id         = "proj",
})
assert(r4 and r4.success, "SetPatch second patch failed")
local p4 = patch_row("seq", 1)
assert(p4 and p4.rec == 1, "second patch rec must be 1")
print("  second patch inserted — OK")

-- ── Bad inputs refuse ────────────────────────────────────────────────────
print("-- bad inputs refused --")
local r_neg = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = -1,   -- negative — violates CHECK (source_track_index >= 0)
    record_track_index = 0,
    project_id         = "proj",
})
assert(not (r_neg and r_neg.success),
    "SetPatch with source_track_index=-1 must fail (CHECK constraint)")
print("  negative source_track_index refused — OK")

print("\n✅ test_set_patch.lua passed")
