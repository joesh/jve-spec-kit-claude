#!/usr/bin/env luajit

-- T018 (015) — patch on/off toggle + plain-drag redirect + invalid-type refusal.
--
-- Domain behaviors under test (derive all expected values from spec, not code):
--   1. Disabling a patch (enabled=0) persists and signals "disabled"
--      (row is kept so the src-btn keeps rendering in dimmed state).
--   2. Re-enabling (enabled=1) persists and signals "updated".
--   3. Plain-drag redirect: SetPatch with record_track_index=N redirects routing.
--   4. Invalid track_type is refused.
--
-- NOT tested here: Insert/Overwrite behavior when channel is disabled (T042).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database      = require("core.database")
local command_manager = require("core.command_manager")
local Signals       = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_patch_toggle_and_drag.lua ===")

local DB = "/tmp/jve/test_patch_toggle_and_drag.db"
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
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
-- 4 video tracks (V1–V4) and 4 audio tracks (A1–A4) for routing tests
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
        ('v1','seq','V1','VIDEO',0,1),
        ('v2','seq','V2','VIDEO',1,1),
        ('v3','seq','V3','VIDEO',2,1),
        ('v4','seq','V4','VIDEO',3,1),
        ('a1','seq','A1','AUDIO',0,1),
        ('a2','seq','A2','AUDIO',1,1),
        ('a3','seq','A3','AUDIO',2,1),
        ('a4','seq','A4','AUDIO',3,1)
]])

command_manager.init("seq", "proj")

local SHAPE = 4  -- fixed source shape (4 audio source channels) for this test

local function patch_row(track_type, src_idx)
    local s = db:prepare(
        "SELECT record_track_index, enabled FROM patches "
        .. "WHERE sequence_id='seq' AND track_type=? "
        .. "AND source_shape=? AND source_track_index=?")
    assert(s)
    s:bind_value(1, track_type); s:bind_value(2, SHAPE); s:bind_value(3, src_idx)
    s:exec()
    if not s:next() then s:finalize(); return nil end
    local r = { rec = s:value(0), enabled = s:value(1) }
    s:finalize()
    return r
end

local signals = {}
Signals.connect("patch_changed",
    function(seq, track_type, shape, src, change_type)
        table.insert(signals, { seq = seq, track_type = track_type,
                                shape = shape, src = src, change_type = change_type })
    end)
local function last_signal() return signals[#signals] end

-- ── 1. Create audio patch A1→A1 (source_track_index=0 AUDIO, rec=0) ──────────
print("-- 1. create A1 patch --")
local r1 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 0,
    record_track_index = 0,
    enabled            = 1,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(r1 and r1.success, "create patch failed: " .. tostring(r1 and r1.error_message))
local p1 = patch_row("AUDIO", 0)
assert(p1 and p1.enabled == 1, "explicit enabled=1 persisted")
assert(p1.rec == 0, "record_track_index must be 0")
print("  A1→A1 created, enabled=1 — OK")

-- ── 2. Disable patch (toggle OFF) ────────────────────────────────────────────
print("-- 2. disable patch (enabled=0) --")
local r2 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 0,
    enabled            = 0,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(r2 and r2.success, "disable patch failed")
local p2 = patch_row("AUDIO", 0)
assert(p2 and p2.enabled == 0, "patch must be disabled after toggle OFF")
local sig2 = last_signal()
assert(sig2 and sig2.change_type == "disabled",
    "signal must carry change_type='disabled' when enabled→0 (row kept; src-btn continues rendering); got: "
    .. tostring(sig2 and sig2.change_type))
print("  disabled, signal='disabled' — OK")

-- ── 3. Re-enable patch (toggle ON) ───────────────────────────────────────────
print("-- 3. re-enable patch (enabled=1) --")
local r3 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 0,
    enabled            = 1,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(r3 and r3.success, "re-enable patch failed")
local p3 = patch_row("AUDIO", 0)
assert(p3 and p3.enabled == 1, "patch must be enabled after toggle ON")
local sig3 = last_signal()
assert(sig3 and sig3.change_type == "updated",
    "signal must be 'updated' on re-enable; got: " .. tostring(sig3 and sig3.change_type))
print("  re-enabled, signal='updated' — OK")

-- ── 4. Plain-drag redirect: A2→A4 (source=1, rec=3) ────────────────────────
print("-- 4. plain-drag redirect A2→A4 --")
-- Create A2 patch first (A2 has track_index=1)
local rc = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 1,
    record_track_index = 1,
    enabled            = 1,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(rc and rc.success, "create A2 patch failed")

-- Drag redirects A2 to A4 (track_index=3)
local r4 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 1,
    record_track_index = 3,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(r4 and r4.success, "redirect failed: " .. tostring(r4 and r4.error_message))
local p4 = patch_row("AUDIO", 1)
assert(p4 and p4.rec == 3,
    "record_track_index must be 3 after redirect; got: " .. tostring(p4 and p4.rec))
print("  A2 redirected to A4 (rec=3) — OK")

-- ── 5. Invalid track_type refused ────────────────────────────────────────────
print("-- 5. invalid track_type refused --")
local r5 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 0,
    record_track_index = 0,
    enabled            = 1,
    track_type         = "MIDI",
    project_id         = "proj",
})
assert(r5 and not r5.success,
    "SetPatch with track_type='MIDI' must fail")
print("  invalid track_type refused — OK")

-- ── 6. SetPatch is not undoable ───────────────────────────────────────────────
print("-- 6. SetPatch is not undoable --")
local before_undo = patch_row("AUDIO", 0)
command_manager.undo()
local after_undo = patch_row("AUDIO", 0)
assert(before_undo and after_undo and before_undo.enabled == after_undo.enabled,
    "SetPatch must not appear on undo stack (enabled changed after undo)")
print("  undo did not revert patch — OK")

print("\n✅ test_patch_toggle_and_drag.lua passed")
