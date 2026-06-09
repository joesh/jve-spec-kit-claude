#!/usr/bin/env luajit

-- T019 (015) — modifier-drag stacking: two source tracks routed to same record row.
--
-- Domain behaviors (FR-010a stacking, FR-029a stacking):
--   1. Stacking: SetPatch(AUDIO, A1→A1), then SetPatch(AUDIO, A2→A1). Both patches
--      must exist with record_track_index=0. UNIQUE is per (type, source_track_index),
--      so two *different* sources can share the same record_track_index.
--   2. After stacking, both patches remain enabled=1.
--   3. Invalid track_type must be refused.
--   4. Stacking does not destroy the pre-existing patch — it creates a second one.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Signals         = require("core.signals")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_modifier_drag_stack.lua ===")

local DB = "/tmp/jve/test_modifier_drag_stack.db"
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
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
        ('v1','seq','V1','VIDEO',0,1),
        ('v2','seq','V2','VIDEO',1,1),
        ('a1','seq','A1','AUDIO',0,1),
        ('a2','seq','A2','AUDIO',1,1),
        ('a3','seq','A3','AUDIO',2,1)
]])

command_manager.init("seq", "proj")

local SHAPE = 2  -- two source audio channels in this test (A1 + A2)

local function audio_patches()
    local rows = {}
    local s = db:prepare(
        "SELECT source_track_index, record_track_index, enabled "
        .. "FROM patches WHERE sequence_id='seq' AND track_type='AUDIO' "
        .. "AND source_shape=? ORDER BY source_track_index ASC")
    assert(s); s:bind_value(1, SHAPE); s:exec()
    while s:next() do
        table.insert(rows, { src = s:value(0), rec = s:value(1), enabled = s:value(2) })
    end
    s:finalize()
    return rows
end

local signals = {}
Signals.connect("patch_changed",
    function(seq, track_type, shape, src, change_type)
        table.insert(signals, { seq = seq, track_type = track_type,
                                shape = shape, src = src, change_type = change_type })
    end)

-- ── 1. Create A1→A1 patch (pre-existing routing) ─────────────────────────────
print("-- 1. create A1→A1 --")
local r1 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 0,
    record_track_index = 0,
    enabled            = 1,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(r1 and r1.success, "create A1→A1 failed: " .. tostring(r1 and r1.error_message))
local rows1 = audio_patches()
assert(#rows1 == 1, "must have exactly 1 AUDIO patch; got " .. #rows1)
assert(rows1[1].rec == 0 and rows1[1].enabled == 1, "A1→A1 patch wrong state")
print("  A1→A1 created, enabled=1 — OK")

-- ── 2. Modifier-drag: stack A2→A1 (same record_track_index=0) ────────────────
print("-- 2. modifier-drag: A2 stacks onto A1's record row --")
local r2 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 1,   -- A2
    record_track_index = 0,   -- A1's record slot
    enabled            = 1,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(r2 and r2.success, "stack A2→A1 failed: " .. tostring(r2 and r2.error_message))

local rows2 = audio_patches()
assert(#rows2 == 2,
    "stacking must produce 2 AUDIO patches (UNIQUE is per type+source_track_index); got " .. #rows2)

local found_a1 = false
local found_a2 = false
for _, row in ipairs(rows2) do
    if row.src == 0 then
        assert(row.rec == 0 and row.enabled == 1,
            "A1 patch must still be rec=0 enabled=1; got rec=" .. row.rec)
        found_a1 = true
    elseif row.src == 1 then
        assert(row.rec == 0 and row.enabled == 1,
            "A2 patch must have rec=0 enabled=1; got rec=" .. row.rec)
        found_a2 = true
    end
end
assert(found_a1, "A1 patch (src=0) missing after stacking")
assert(found_a2, "A2 patch (src=1) missing after stacking")
print("  A1→A1 and A2→A1 both exist, both enabled=1 — OK")

-- ── 3. Pre-existing patch A1 not destroyed by stacking ───────────────────────
print("-- 3. pre-existing A1 patch unaffected --")
local s = db:prepare(
    "SELECT record_track_index FROM patches "
    .. "WHERE sequence_id='seq' AND track_type='AUDIO' AND source_track_index=0")
assert(s); s:exec(); assert(s:next())
local a1_rec_after = s:value(0); s:finalize()
assert(a1_rec_after == 0,
    "A1 record_track_index must remain 0 after A2 stacks; got " .. tostring(a1_rec_after))
print("  A1 patch record_track_index unchanged — OK")

-- ── 4. Invalid track_type must be refused ─────────────────────────────────────
print("-- 4. invalid track_type refused --")
local r4 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 0,
    record_track_index = 0,
    enabled            = 1,
    track_type         = "MIDI",   -- not a valid type
    project_id         = "proj",
})
assert(r4 and not r4.success,
    "SetPatch with track_type='MIDI' must fail")
print("  invalid track_type refused — OK")

-- ── 5. Signal emitted for each stacking operation ─────────────────────────────
print("-- 5. patch_changed signals emitted --")
local a1_sigs = 0; local a2_sigs = 0
for _, sig in ipairs(signals) do
    if sig.track_type == "AUDIO" then
        if sig.src == 0 then a1_sigs = a1_sigs + 1 end
        if sig.src == 1 then a2_sigs = a2_sigs + 1 end
    end
end
assert(a1_sigs >= 1, "patch_changed must fire for A1 (src=0)")
assert(a2_sigs >= 1, "patch_changed must fire for A2 stack (src=1)")
print("  signals emitted for both patches — OK")

print("\n✅ test_modifier_drag_stack.lua passed")
