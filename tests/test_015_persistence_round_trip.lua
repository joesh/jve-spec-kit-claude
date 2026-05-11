#!/usr/bin/env luajit

-- 015 — FR-030 + FR-039 + FR-028: patches and tracks.sync_mode persist
-- in the project DB and are restored verbatim on reopen.
--
-- Spec FR-030: "Patches MUST be persisted in the project DB and restored
-- verbatim on reopen."
-- Spec FR-039: "Per-track sync_mode and patches MUST persist via the
-- schema migration (FR-046). Restored verbatim on sequence reopen."
--
-- Round-trip: write state, close DB, reopen, read same state.
-- Verifies that no in-memory caching hides a missing persistence write.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_delay, cb) cb(); return nil end

print("=== test_015_persistence_round_trip.lua ===")

local DB = "/tmp/jve/test_015_persistence_round_trip.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")

-- ── Phase 1: open, write state, close ────────────────────────────────────
print("-- (1) write state into fresh DB --")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'nested', 24, 1, 48000, 1920, 1080, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, sync_mode)
    VALUES
      ('trk_v1', 'seq', 'V1', 'VIDEO', 1, 1, 'ripple'),
      ('trk_a1', 'seq', 'A1', 'AUDIO', 1, 1, 'ripple'),
      ('trk_a2', 'seq', 'A2', 'AUDIO', 2, 1, 'ripple');
]], now, now, now, now))

command_manager.init("seq", "proj")

-- Write three patches (one VIDEO, two AUDIO; one with non-identity rec).
command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    track_type         = "VIDEO",
    source_track_index = 1,
    record_track_index = 1,
    project_id         = "proj",
    enabled            = 1,
})
command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    track_type         = "AUDIO",
    source_track_index = 1,
    record_track_index = 2,   -- non-identity dragged route
    project_id         = "proj",
    enabled            = 1,
})
command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    track_type         = "AUDIO",
    source_track_index = 2,
    record_track_index = 2,
    project_id         = "proj",
    enabled            = 0,   -- explicitly OFF
})

-- Set distinct sync_modes per track.
command_manager.execute("SetSyncMode", {
    track_id = "trk_v1", sync_mode = "off",    project_id = "proj",
})
command_manager.execute("SetSyncMode", {
    track_id = "trk_a1", sync_mode = "cut",    project_id = "proj",
})
command_manager.execute("SetSyncMode", {
    track_id = "trk_a2", sync_mode = "ripple", project_id = "proj",
})

-- Capture canonical state from the live DB before close.
local function snapshot()
    local out = { patches = {}, sync_modes = {} }
    local s = db:prepare(
        "SELECT track_type, source_track_index, record_track_index, enabled, color "
        .. "FROM patches WHERE sequence_id='seq' "
        .. "ORDER BY track_type, source_track_index")
    s:exec()
    while s:next() do
        table.insert(out.patches, {
            type = s:value(0), src = s:value(1), rec = s:value(2),
            enabled = s:value(3), color = s:value(4),
        })
    end
    s:finalize()
    local t = db:prepare(
        "SELECT id, sync_mode FROM tracks WHERE sequence_id='seq' ORDER BY id")
    t:exec()
    while t:next() do
        out.sync_modes[t:value(0)] = t:value(1)
    end
    t:finalize()
    return out
end

local before = snapshot()
assert(#before.patches == 3, string.format(
    "FAIL: expected 3 patches before close, got %d", #before.patches))

database.shutdown()
print("  3 patches + 3 sync_modes written; DB closed")

-- ── Phase 2: reopen the SAME DB file, read same state verbatim ──────────
print("-- (2) reopen DB; verify state matches verbatim --")
database.init(DB)
db = database.get_connection()

local after = snapshot()

assert(#after.patches == #before.patches, string.format(
    "FAIL: patch count differs after reopen: before=%d after=%d",
    #before.patches, #after.patches))

for i, b in ipairs(before.patches) do
    local a = after.patches[i]
    assert(a.type == b.type and a.src == b.src and a.rec == b.rec
           and a.enabled == b.enabled and a.color == b.color, string.format(
        "FAIL: patch[%d] differs after reopen — before=(%s/%d→%d en=%d %s) "
        .. "after=(%s/%d→%d en=%d %s)",
        i, b.type, b.src, b.rec, b.enabled, b.color,
        a.type, a.src, a.rec, a.enabled, a.color))
end
print(string.format("  all %d patches restored verbatim — OK", #after.patches))

for tid, mode in pairs(before.sync_modes) do
    assert(after.sync_modes[tid] == mode, string.format(
        "FAIL: sync_mode for %s differs after reopen — before=%s after=%s",
        tid, mode, tostring(after.sync_modes[tid])))
end
print("  all 3 sync_modes restored verbatim — OK")

database.shutdown()
print("\nâœ… test_015_persistence_round_trip.lua passed")
