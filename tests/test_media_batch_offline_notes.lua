#!/usr/bin/env luajit
-- Regression: Media.batch_set_offline_notes + batch_clear_offline_notes.
--
-- These are the DB writers the relink pipeline uses to record and
-- clear partial-coverage diagnostics. A bug in either silently breaks
-- the offline-frame's shortfall message — clips either render generic
-- "File not found" even when a note exists (missed write), or keep a
-- stale note after the user successfully relinks (missed clear).
--
-- Domain contract:
--   * batch_set_offline_notes writes a JSON string to media.offline_note
--     for each {id → note} pair. No-op on empty input.
--   * batch_clear_offline_notes nulls media.offline_note for each id.
--     No-op on empty array.
--   * The two APIs are the ONLY way to write the column from the
--     relinker (Lua pairs() can't iterate nil values, so a combined
--     "value-or-nil" map with implicit semantics doesn't work).

require('test_env')

local database = require('core.database')
local Media    = require('models.media')

local DB_PATH = "/tmp/jve/test_media_batch_offline_notes.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "db init failed")
local conn = database.get_connection()
conn:exec(require('import_schema'))

local PROJ = "prj-batch-notes"
local M1, M2, M3 = "m1", "m2", "m3"
local P1, P2, P3 = "/fixture/A.mov", "/fixture/B.mov", "/fixture/C.mov"

assert(conn:exec(string.format([[
INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
VALUES ('%s', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO media (id, project_id, name, file_path, duration_frames,
    fps_numerator, fps_denominator, is_still, offline_note,
    created_at, modified_at)
VALUES
('%s', '%s', 'A', '%s', 100, 25, 1, 0, NULL, strftime('%%s','now'), strftime('%%s','now')),
('%s', '%s', 'B', '%s', 100, 25, 1, 0, NULL, strftime('%%s','now'), strftime('%%s','now')),
('%s', '%s', 'C', '%s', 100, 25, 1, 0, NULL, strftime('%%s','now'), strftime('%%s','now'));
]], PROJ, M1, PROJ, P1, M2, PROJ, P2, M3, PROJ, P3)), "seed")

local function get_note(mid)
    local stmt = assert(conn:prepare("SELECT offline_note FROM media WHERE id = ?"))
    stmt:bind_value(1, mid)
    assert(stmt:exec())
    if not stmt:next() then stmt:finalize(); return nil end
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

print("=== Media.batch_set_offline_notes + batch_clear_offline_notes ===")

-- 1. No-op on empty input.
Media.batch_set_offline_notes({})
Media.batch_clear_offline_notes({})
assert(get_note(M1) == nil, "empty set must leave row alone")
print("  OK: empty input no-ops")

-- 2. Set writes JSON for each id.
local NOTE_A = '{"kind":"partial_coverage","candidate_path":"' .. P1 .. '",' ..
    '"covered_start_tc":0,"covered_end_tc":50,"rate":25}'
local NOTE_B = '{"kind":"partial_coverage","candidate_path":"' .. P2 .. '",' ..
    '"covered_start_tc":10,"covered_end_tc":90,"rate":25}'
Media.batch_set_offline_notes({ [M1] = NOTE_A, [M2] = NOTE_B })
assert(get_note(M1) == NOTE_A, string.format(
    "m1 note must equal NOTE_A; got %s", tostring(get_note(M1))))
assert(get_note(M2) == NOTE_B, string.format(
    "m2 note must equal NOTE_B; got %s", tostring(get_note(M2))))
assert(get_note(M3) == nil, "untouched row stays nil")
print("  OK: set writes JSON per id")

-- 3. Clear nulls specific rows without touching others.
Media.batch_clear_offline_notes({ M1 })
assert(get_note(M1) == nil, "m1 cleared")
assert(get_note(M2) == NOTE_B, "m2 preserved")
print("  OK: clear nulls only listed ids")

-- 4. Set on a row with an existing note OVERWRITES (relink again with
--    a different short candidate).
local NOTE_A2 = '{"kind":"partial_coverage","candidate_path":"' .. P1 .. '",' ..
    '"covered_start_tc":20,"covered_end_tc":80,"rate":25}'
Media.batch_set_offline_notes({ [M2] = NOTE_A2 })
assert(get_note(M2) == NOTE_A2, string.format(
    "set must overwrite prior note; got %s", tostring(get_note(M2))))
print("  OK: set overwrites existing note")

-- 5. Set asserts on non-string value — the API contract requires JSON
--    strings only; callers must route clears through batch_clear_offline_notes.
local ok, err = pcall(Media.batch_set_offline_notes, { [M3] = 42 })
assert(not ok, "set must reject non-string values")
assert(tostring(err):find("must be string"), string.format(
    "error must explain shape: %s", tostring(err)))
print("  OK: set rejects non-string values with actionable message")

-- 6. Set asserts on nil value too — pairs() would skip it silently;
--    explicit assert surfaces the caller bug instead.
--    (Note: with pairs(), nil values literally don't appear, so this
--    path only triggers if callers pass an array of {id, nil}-style
--    structure. We assert the direct case still by checking the key
--    doesn't land.)
local sets_with_nil = { [M3] = nil }  -- nil drops the key
Media.batch_set_offline_notes(sets_with_nil)  -- no-op, no crash
assert(get_note(M3) == nil, "nil-valued key is invisible, no write")
print("  OK: nil-valued key silently dropped (pairs() semantics)")

-- 7. Clearing an id that isn't in the table is a silent no-op
--    (UPDATE ... WHERE id=? with a miss matches 0 rows, no error).
Media.batch_clear_offline_notes({ "nonexistent-id" })
assert(get_note(M2) == NOTE_A2, "unrelated row untouched by miss clear")
print("  OK: clear of missing id is silent no-op")

print("✅ test_media_batch_offline_notes.lua passed")
