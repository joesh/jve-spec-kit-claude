#!/usr/bin/env luajit
-- Regression: the renderer must never query the DB on the render path.
-- offline_note (the relinker's partial-coverage diagnostic) lives on the
-- media row; the renderer needs it by media_path when composing the
-- offline frame. media_status is the renderer-facing projection of
-- per-media render state, so it owns the in-memory offline_note cache
-- alongside {offline, error_code}. This test pins that API.
--
-- Domain behavior under test (derived from the partial-coverage contract,
-- not from tracing code):
--   * After reading offline_notes from the project DB, the note written
--     on a media row is retrievable by its file_path.
--   * A media row with no note reports nil (no diagnostic available).
--   * On media_changed (relink writes a new note), the cache picks up
--     the new value so subsequent renders see the updated diagnostic.

require('test_env')

local database = require('core.database')
local media_status = require('core.media.media_status')
local Signals = require('core.signals')

local DB_PATH = "/tmp/jve/test_media_status_offline_note_from_db.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "db init failed")
local conn = database.get_connection()
conn:exec(require('import_schema'))

local PROJ = "prj-offline-note"
local M_WITH_NOTE = "mid-with-note"
local M_NO_NOTE = "mid-no-note"
local PATH_WITH = "/fixture/covered.mov"
local PATH_WITHOUT = "/fixture/plain.mov"

local NOTE_JSON = '{"kind":"partial_coverage","candidate_path":"/fixture/covered.mov",' ..
    '"covered_start_tc":86400,"covered_end_tc":86500,"rate":25}'

assert(conn:exec(string.format([[
INSERT INTO projects (id, name, created_at, modified_at)
VALUES ('%s', 'Test', strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO media (id, project_id, name, file_path, duration_frames,
    fps_numerator, fps_denominator, is_still, offline_note, created_at, modified_at)
VALUES
('%s', '%s', 'covered.mov', '%s', 100, 25, 1, 0, '%s',
    strftime('%%s','now'), strftime('%%s','now')),
('%s', '%s', 'plain.mov', '%s', 100, 25, 1, 0, NULL,
    strftime('%%s','now'), strftime('%%s','now'));
]], PROJ, M_WITH_NOTE, PROJ, PATH_WITH, NOTE_JSON,
    M_NO_NOTE, PROJ, PATH_WITHOUT)), "seed insert failed")

print("=== media_status offline_note cache from DB ===")

-- 1. Reading from DB populates the cache; renderer queries by path.
media_status.read_offline_notes_from_db()
assert(media_status.get_offline_note(PATH_WITH) == NOTE_JSON,
    string.format("expected note JSON for %s, got %s",
        PATH_WITH, tostring(media_status.get_offline_note(PATH_WITH))))
assert(media_status.get_offline_note(PATH_WITHOUT) == nil,
    "media with no offline_note must report nil (no diagnostic to render)")
print("  OK: notes read from DB, absent note reports nil")

-- 2. Relink writes a new note → media_changed signal → cache refreshes.
local NEW_NOTE = '{"kind":"partial_coverage","candidate_path":"/fixture/plain.mov",' ..
    '"covered_start_tc":0,"covered_end_tc":50,"rate":25}'
assert(conn:exec(string.format(
    "UPDATE media SET offline_note = '%s' WHERE id = '%s';",
    NEW_NOTE, M_NO_NOTE)), "UPDATE failed")

Signals.emit("media_changed", { [M_NO_NOTE] = true })

assert(media_status.get_offline_note(PATH_WITHOUT) == NEW_NOTE,
    string.format("after media_changed, cache must reflect new note; got %s",
        tostring(media_status.get_offline_note(PATH_WITHOUT))))
print("  OK: cache picks up note updates via media_changed")

-- 3. Clearing the note (relink succeeds) → cache reflects nil.
assert(conn:exec(string.format(
    "UPDATE media SET offline_note = NULL WHERE id = '%s';",
    M_WITH_NOTE)), "UPDATE NULL failed")

Signals.emit("media_changed", { [M_WITH_NOTE] = true })

assert(media_status.get_offline_note(PATH_WITH) == nil,
    string.format("after note cleared, cache must report nil; got %s",
        tostring(media_status.get_offline_note(PATH_WITH))))
print("  OK: cache reflects note clearing (successful relink)")

print("✅ test_media_status_offline_note_from_db.lua passed")
