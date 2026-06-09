#!/usr/bin/env luajit
-- End-to-end prproj import: drives the full convert pipeline on the
-- anamnesis fixture and asserts the resulting .jvp matches what a user
-- would see when opening the project.
--
-- Pipeline: open_project._convert_prproj_to_jvp(prproj, jvp) → fresh
-- SQLite DB → query rows directly. No UI; no command dispatch. This
-- exercises the same convert path the user hits when opening a .prproj
-- via File → Open: lifecycle (open_project) + format-knowledge
-- (prproj_importer) + entity-creation (importer_core).
--
-- Domain expectations (derived from the fixture's content, NOT from
-- tracing the parser):
--   • Project name = .prproj basename
--   • One imported sequence (the anamnesis main timeline)
--   • Sequence fps matches the .prproj VideoTrackGroup FrameRate (25)
--   • Sequence dimensions match VideoTrackGroup FrameRect (2048×1152)
--   • Hundreds of media rows imported (the fixture has 614 Media
--     elements — at least 400 should survive importer dedup/filter)
--   • At least one media row carries start_tc_value (the AlternateStart
--     fix, this session — without it no camera media would have TC)
--   • The sequence carries clips (the fixture has 2881 clips parsed;
--     importer may drop some — assert at least 1000 land in DB)
--
-- All thresholds are LOOSE LOWER BOUNDS keyed to fixture content. The
-- test is intentionally not pixel-exact on counts — the importer's
-- dedup / filter behavior is verified by other unit tests; this one
-- checks the pipeline composes end-to-end.

local test_env = require("test_env")

local open_project = require("core.commands.open_project")
local database = require("core.database")

print("=== test_prproj_import_e2e.lua ===")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/premiere/2026-03-20-anamnesis joe edit.prproj")
local JVP_PATH = "/tmp/jve/test_prproj_import_e2e.jvp"

os.execute("mkdir -p /tmp/jve")
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-shm")
os.remove(JVP_PATH .. "-wal")

print("Converting fixture → " .. JVP_PATH)
local start_clock = os.clock()
local ok = open_project._convert_prproj_to_jvp(FIXTURE, JVP_PATH)
assert(ok, "convert returned non-truthy result")
local elapsed = os.clock() - start_clock
print(string.format("  convert took %.2fs", elapsed))

-- ─── Reconnect to the created DB and query directly ──────────────────
database.init(JVP_PATH)
local db = database.get_connection()

local function scalar(sql)
    local stmt = db:prepare(sql)
    stmt:exec()
    stmt:next()
    local v = stmt:value(0)
    stmt:finalize()
    return v
end

-- Project row exists and carries the expected name.
local project_name = scalar("SELECT name FROM projects LIMIT 1")
assert(project_name == "2026-03-20-anamnesis joe edit", string.format(
    "expected project name from .prproj basename, got %q", tostring(project_name)))
print("  ✓ project: " .. project_name)

-- Sequences: master clips + 1 timeline. The fixture has one main
-- timeline. Filter by kind to count user-visible timelines.
local timeline_count = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'sequence'")
assert(timeline_count >= 1, string.format(
    "expected ≥1 imported timeline, got %s", tostring(timeline_count)))
print(string.format("  ✓ timelines: %d (kind='sequence')", timeline_count))

local seq_stmt = db:prepare([[
    SELECT name, fps_numerator, fps_denominator, width, height
    FROM sequences WHERE kind = 'sequence' LIMIT 1
]])
seq_stmt:exec()
seq_stmt:next()
local seq_name = seq_stmt:value(0)
local fps_num  = seq_stmt:value(1)
local fps_den  = seq_stmt:value(2)
local width    = seq_stmt:value(3)
local height   = seq_stmt:value(4)
seq_stmt:finalize()

assert(fps_num and fps_den and fps_num > 0 and fps_den > 0, string.format(
    "sequence missing fps: num=%s den=%s", tostring(fps_num), tostring(fps_den)))
local fps = fps_num / fps_den
assert(math.abs(fps - 25) < 0.001, string.format(
    "expected fps≈25 (prproj VideoTrackGroup FrameRate), got %.3f", fps))
assert(width == 2048 and height == 1152, string.format(
    "expected 2048×1152, got %dx%d", width, height))
print(string.format("  ✓ sequence %q: %d/%d fps, %dx%d",
    seq_name, fps_num, fps_den, width, height))

-- Media rows: importer dedup may collapse some; loose lower bound from
-- fixture content (614 Media elements in source).
local media_count = scalar("SELECT COUNT(*) FROM media")
assert(media_count >= 400, string.format(
    "expected ≥400 media rows post-import, got %d", media_count))
print(string.format("  ✓ media rows: %d", media_count))

-- TC origin: the AlternateStart fix this session. At least one camera
-- file must have a non-null start_tc_value in its metadata JSON.
-- Substring match keeps the test resilient to JSON ordering.
local tc_count = scalar([[
    SELECT COUNT(*) FROM media
    WHERE metadata LIKE '%"start_tc_value"%'
]])
assert(tc_count >= 100, string.format(
    "expected ≥100 media with start_tc_value (camera files w/ AlternateStart), got %d",
    tc_count))
print(string.format("  ✓ media with TC origin: %d", tc_count))

-- Clips landed on the timeline. The fixture has 2881 parsed clips;
-- some may be filtered (offline-only, zero-duration). Loose bound.
local clip_count = scalar([[
    SELECT COUNT(*) FROM clips c
    JOIN tracks t ON c.track_id = t.id
    JOIN sequences s ON t.sequence_id = s.id
    WHERE s.kind = 'sequence'
]])
assert(clip_count >= 1000, string.format(
    "expected ≥1000 clips imported on timeline tracks, got %d", clip_count))
print(string.format("  ✓ clips on timeline: %d", clip_count))

-- Tracks created on the timeline.
local track_count = scalar([[
    SELECT COUNT(*) FROM tracks t
    JOIN sequences s ON t.sequence_id = s.id
    WHERE s.kind = 'sequence'
]])
assert(track_count >= 10, string.format(
    "expected ≥10 tracks (fixture has 20), got %d", track_count))
print(string.format("  ✓ tracks: %d", track_count))

os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-shm")
os.remove(JVP_PATH .. "-wal")

print("\n✅ test_prproj_import_e2e.lua passed")
