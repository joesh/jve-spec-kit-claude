#!/usr/bin/env luajit
-- Regression: relink_planner.build_plan emits media_offline_notes as a
-- JSON-encoded map keyed by media_id, with a "__clear__" sentinel for
-- media that got a clean (non-partial) relink so any lingering note
-- from a prior run gets wiped by the RelinkClips executor.
--
-- Domain contract:
--   * Input: relinked[] entries, some carrying a `coverage` table
--     (partial_coverage strategy).
--   * Output: plan.media_offline_notes = {
--       [partial_media_id] = <json string of coverage>,
--       [clean_media_id]   = "__clear__",
--     }
--   * Clean media that wasn't path-changed doesn't appear (nothing to
--     clear — the row's current note is already accurate).
--
-- This contract is what lets the RelinkClips executor split incoming
-- changes into Media.batch_set_offline_notes (JSON sets) and
-- batch_clear_offline_notes (clears). A broken producer silently drops
-- partial-coverage diagnostics OR leaves stale notes on cleanly-
-- relinked media.

require('test_env')

local database = require('core.database')
local relink_planner = require('core.relink_planner')
local json = require('dkjson')

local DB_PATH = "/tmp/jve/test_relink_planner_offline_notes.db"
os.remove(DB_PATH); os.remove(DB_PATH .. "-wal"); os.remove(DB_PATH .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "db init")
local db = database.get_connection()
db:exec(require('import_schema'))

local PROJ = "prj-notes"
local M_PARTIAL, M_CLEAN = "m-partial", "m-clean"
local P_PARTIAL_OLD = "/old/A.mov"
local P_CLEAN_OLD   = "/old/B.mov"
local P_PARTIAL_NEW = "/new/A_short.mov"
local P_CLEAN_NEW   = "/new/B.mov"

assert(db:exec(string.format([[
INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
VALUES ('%s', 'Test', 'resample', strftime('%%s','now'), strftime('%%s','now'));
INSERT INTO media (id, project_id, name, file_path, duration_frames,
    fps_numerator, fps_denominator, is_still, offline_note,
    created_at, modified_at)
VALUES
('%s', '%s', 'A', '%s', 100, 25, 1, 0, NULL, strftime('%%s','now'), strftime('%%s','now')),
('%s', '%s', 'B', '%s', 100, 25, 1, 0, NULL, strftime('%%s','now'), strftime('%%s','now'));
]], PROJ, M_PARTIAL, PROJ, P_PARTIAL_OLD, M_CLEAN, PROJ, P_CLEAN_OLD)), "seed")

print("=== relink_planner.build_plan → media_offline_notes ===")

local coverage = {
    kind = "partial_coverage",
    candidate_path = P_PARTIAL_NEW,
    covered_start_tc = 86400,
    covered_end_tc   = 86500,
    rate = 25,
}
local relinked = {
    { media_id = M_PARTIAL, new_path = P_PARTIAL_NEW,
      strategy = "partial_coverage", coverage = coverage },
    { media_id = M_CLEAN,   new_path = P_CLEAN_NEW,
      strategy = "filename" },
}
local failed = {}
local folder_priority = { "/new" }

local plan = relink_planner.build_plan(db, relinked, failed, folder_priority, PROJ)

-- 1. Partial-coverage media must emit a JSON-encoded note.
local encoded = plan.media_offline_notes[M_PARTIAL]
assert(type(encoded) == "string" and encoded ~= "" and encoded ~= "__clear__",
    string.format("partial-coverage media must get JSON note; got %s", tostring(encoded)))

-- 2. JSON round-trips back to the original coverage shape.
local decoded = json.decode(encoded)
assert(type(decoded) == "table", "note must decode to a table")
assert(decoded.kind == "partial_coverage", string.format(
    "decoded.kind = %s", tostring(decoded.kind)))
assert(decoded.candidate_path == P_PARTIAL_NEW, string.format(
    "decoded.candidate_path = %s", tostring(decoded.candidate_path)))
assert(decoded.covered_start_tc == 86400, string.format(
    "decoded.covered_start_tc = %s", tostring(decoded.covered_start_tc)))
assert(decoded.covered_end_tc == 86500, string.format(
    "decoded.covered_end_tc = %s", tostring(decoded.covered_end_tc)))
assert(decoded.rate == 25, string.format(
    "decoded.rate = %s", tostring(decoded.rate)))
print("  OK: partial-coverage note round-trips through JSON")

-- 3. Clean relink emits the "__clear__" sentinel — any previously-
--    written note on that media must be wiped by the executor.
assert(plan.media_offline_notes[M_CLEAN] == "__clear__",
    string.format("clean relink must emit '__clear__' sentinel; got %s",
        tostring(plan.media_offline_notes[M_CLEAN])))
print("  OK: clean relink emits '__clear__' sentinel")

-- 4. Media absent from relinked[] doesn't appear in the notes map —
--    no spurious clears for media that wasn't touched.
local absent_count = 0
for _ in pairs(plan.media_offline_notes) do absent_count = absent_count + 1 end
assert(absent_count == 2, string.format(
    "only relinked media should appear in media_offline_notes; got %d entries",
    absent_count))
print("  OK: untouched media stays out of notes map")

print("✅ test_relink_planner_offline_notes.lua passed")
