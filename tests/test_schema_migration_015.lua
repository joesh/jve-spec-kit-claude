#!/usr/bin/env luajit

-- T004 (015) — Schema migration: tracks.sync_mode column + patches table.
--
-- Domain: after the 015 migration runs, the DB must enforce:
--   * tracks.sync_mode IN ('off','ripple','cut')  NOT NULL  DEFAULT 'ripple'
--   * patches(id, sequence_id, track_type, source_track_index, record_track_index, enabled)
--     with UNIQUE(sequence_id, track_type, source_track_index) and CASCADE on seq delete
--   * schema_version bumped to 10
--   * snapshots and clip_links tables unchanged (no regressions)
--   * pre-existing tracks default to sync_mode='ripple'

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")
local database = require("core.database")

print("=== test_schema_migration_015.lua ===")

local DB = "/tmp/jve/test_schema_migration_015.db"
os.remove(DB)
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()

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

-- ── Existing track (must acquire default sync_mode='ripple') ──────────────
local ok_trk = db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('trk_pre', 'seq', 'V1', 'VIDEO', 1, 1)
]])
assert(ok_trk, "pre-existing track INSERT failed")
print("  pre-existing track inserted")

-- ── tracks.sync_mode column exists ───────────────────────────────────────
local val_stmt = db:prepare("SELECT sync_mode FROM tracks WHERE id = 'trk_pre'")
assert(val_stmt, "FAIL: tracks.sync_mode column missing — migration not applied")
val_stmt:exec(); val_stmt:next()
local sm = val_stmt:value(0)
val_stmt:finalize()
assert(sm == "ripple", string.format(
    "FAIL: pre-existing track sync_mode='%s', expected 'ripple' (DEFAULT not applied)",
    tostring(sm)))
print("  pre-existing track: sync_mode='ripple' default — OK")

-- ── sync_mode CHECK constraint ────────────────────────────────────────────
local bad_ok = db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, sync_mode)
    VALUES ('trk_bad', 'seq', 'Bad', 'VIDEO', 2, 1, 'invalid_mode')
]])
assert(not bad_ok, "FAIL: sync_mode CHECK constraint did not reject 'invalid_mode'")
print("  sync_mode CHECK rejects bad value — OK")

-- ── patches table exists with track_type column ──────────────────────────
local p1 = db:exec([[
    INSERT INTO patches (id, sequence_id, track_type, source_track_index, record_track_index, enabled)
    VALUES ('p1', 'seq', 'AUDIO', 0, 0, 1)
]])
assert(p1, "FAIL: patches table missing or columns wrong")
print("  patches INSERT — OK")

-- ── UNIQUE(sequence_id, track_type, source_track_index) ──────────────────
local dup = db:exec([[
    INSERT INTO patches (id, sequence_id, track_type, source_track_index, record_track_index, enabled)
    VALUES ('p_dup', 'seq', 'AUDIO', 0, 1, 1)
]])
assert(not dup, "FAIL: UNIQUE(sequence_id, track_type, source_track_index) not enforced")
print("  UNIQUE constraint blocks duplicate — OK")

-- ── record_track_index may exceed track count (no FK) ────────────────────
local p_far = db:exec([[
    INSERT INTO patches (id, sequence_id, track_type, source_track_index, record_track_index, enabled)
    VALUES ('p_far', 'seq', 'AUDIO', 1, 99, 1)
]])
assert(p_far, "FAIL: record_track_index=99 (exceeds track count) must be allowed — no FK")
print("  record_track_index may exceed track count — OK")

-- ── CASCADE: delete sequence removes patches ─────────────────────────────
local cnt_before = (function()
    local s = db:prepare("SELECT COUNT(*) FROM patches WHERE sequence_id = 'seq'")
    assert(s); s:exec(); s:next(); local v = s:value(0); s:finalize(); return v
end)()
assert(cnt_before >= 2, "expected >=2 patches before cascade test, got " .. tostring(cnt_before))
db:exec("DELETE FROM sequences WHERE id = 'seq'")
local cnt_after = (function()
    local s = db:prepare("SELECT COUNT(*) FROM patches WHERE sequence_id = 'seq'")
    assert(s); s:exec(); s:next(); local v = s:value(0); s:finalize(); return v
end)()
assert(cnt_after == 0, string.format(
    "FAIL: CASCADE delete did not remove patches — %d rows remain", cnt_after))
print("  CASCADE on sequence delete — OK")

-- ── schema_version == 10 ─────────────────────────────────────────────────
local sv_stmt = db:prepare("SELECT MAX(version) FROM schema_version")
assert(sv_stmt); sv_stmt:exec(); sv_stmt:next()
local sv = sv_stmt:value(0)
sv_stmt:finalize()
assert(sv == 10, string.format("FAIL: schema_version=%s, expected 10", tostring(sv)))
print("  schema_version=10 — OK")

-- ── snapshots table unchanged (no regressions) ───────────────────────────
local snap_col = db:prepare(
    "SELECT COUNT(*) FROM pragma_table_info('snapshots') WHERE name='clips_state'")
assert(snap_col)
snap_col:exec(); snap_col:next()
assert(snap_col:value(0) == 1, "FAIL: snapshots.clips_state column missing")
snap_col:finalize()
local snap_extra = db:prepare(
    "SELECT COUNT(*) FROM pragma_table_info('snapshots')")
assert(snap_extra)
snap_extra:exec(); snap_extra:next()
local snap_col_count = snap_extra:value(0)
snap_extra:finalize()
assert(snap_col_count == 5, string.format(
    "FAIL: snapshots table has %d columns, expected 5 (id,sequence_id,sequence_number,clips_state,created_at)",
    snap_col_count))
print("  snapshots table unchanged — OK")

-- ── clip_links table unchanged ────────────────────────────────────────────
local cl_stmt = db:prepare(
    "SELECT COUNT(*) FROM pragma_table_info('clip_links')")
assert(cl_stmt)
cl_stmt:exec(); cl_stmt:next()
local cl_count = cl_stmt:value(0)
cl_stmt:finalize()
assert(cl_count == 6, string.format(
    "FAIL: clip_links column count=%d, expected 6 (id,link_group_id,clip_id,role,time_offset,enabled)",
    cl_count))
print("  clip_links table present and unchanged — OK")

print("\n✅ test_schema_migration_015.lua passed")
