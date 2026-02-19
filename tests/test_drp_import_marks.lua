#!/usr/bin/env luajit

-- Regression: DRP pool_master_clip marks (mark_in, mark_out, playhead) must
-- propagate to JVE master clips after import.

require("test_env")

local drp_importer = require("importers.drp_importer")
local database = require("core.database")

local test_env = require("test_env")
local fixture_path = test_env.resolve_repo_path("tests/fixtures/resolve/sample_project.drp")

local JVP_PATH = "/tmp/jve/test_drp_import_marks.jvp"
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("\n=== DRP Import Marks ===")

-- ======================================================================
-- Setup: parse DRP to get pool_master_clips with expected playhead values
-- ======================================================================
print("Step 1: Parsing DRP to extract expected marks...")
local parse_result = drp_importer.parse_drp_file(fixture_path)
assert(parse_result.success, "parse_drp_file failed: " .. tostring(parse_result.error))

-- Build expected playhead map from pool_master_clips (name → playhead)
local expected_playheads = {}
local clips_with_playhead = 0
for _, pmc in ipairs(parse_result.pool_master_clips) do
    if pmc.playhead and pmc.playhead > 0 then
        -- Store by name+type (some media have both video and audio pool entries)
        local key = pmc.name .. ":" .. pmc.clip_type
        expected_playheads[key] = pmc.playhead
        clips_with_playhead = clips_with_playhead + 1
    end
end
print(string.format("  Found %d pool master clips with non-zero playhead", clips_with_playhead))
assert(clips_with_playhead > 0, "Fixture should have at least one clip with non-zero playhead")

-- ======================================================================
-- Convert DRP to JVP (exercises the full import pipeline)
-- ======================================================================
print("Step 2: Converting DRP...")
local ok, err = drp_importer.convert(fixture_path, JVP_PATH)
assert(ok, "convert failed: " .. tostring(err))

local db = database.get_connection()
assert(db, "No database connection after convert")

-- Helper: run scalar query
local function scalar(sql, ...)
    local stmt = assert(db:prepare(sql), "prepare failed: " .. sql)
    local args = {...}
    for i, v in ipairs(args) do stmt:bind_value(i, v) end
    assert(stmt:exec(), "exec failed: " .. sql)
    local val = nil
    if stmt:next() then val = stmt:value(0) end
    stmt:finalize()
    return val
end

-- ======================================================================
-- Test 1: Master clips with non-zero playhead have it persisted
-- ======================================================================
print("Test 1: Master clip playhead propagation...")

-- Get all master clips with their media names and playhead_frame values
local stmt = db:prepare([[
    SELECT c.id, c.name, c.playhead_frame, c.mark_in_frame, c.mark_out_frame,
           m.name as media_name,
           t.track_type
    FROM clips c
    JOIN media m ON c.media_id = m.id
    JOIN tracks t ON c.track_id = t.id
    WHERE c.clip_kind = 'master'
]])
assert(stmt, "Failed to prepare master clips query")
assert(stmt:exec(), "Master clips query failed")

local master_clips_checked = 0
local playheads_matched = 0
while stmt:next() do
    local _clip_id = stmt:value(0)   -- luacheck: ignore 211
    local clip_name = stmt:value(1)
    local playhead = stmt:value(2)
    local _mark_in = stmt:value(3)  -- luacheck: ignore 211
    local _mark_out = stmt:value(4) -- luacheck: ignore 211
    local media_name = stmt:value(5)
    local track_type = stmt:value(6)

    master_clips_checked = master_clips_checked + 1

    -- Map track_type to pool clip_type
    local clip_type = track_type == "AUDIO" and "audio" or "video"
    local key = media_name .. ":" .. clip_type

    local expected = expected_playheads[key]
    if expected then
        assert(playhead == expected, string.format(
            "Master clip '%s' (media=%s, type=%s): playhead=%s, expected=%s",
            clip_name, media_name, clip_type, tostring(playhead), tostring(expected)))
        playheads_matched = playheads_matched + 1
    end
end
stmt:finalize()

print(string.format("  Checked %d master clips, %d playheads matched", master_clips_checked, playheads_matched))
assert(playheads_matched > 0, "Expected at least one playhead match")
print("  OK")

-- ======================================================================
-- Test 2: Timeline clips do NOT have marks (marks live on master clips)
-- ======================================================================
print("Test 2: Timeline clips have no marks...")
local tl_mark_count = scalar([[
    SELECT COUNT(*) FROM clips
    WHERE clip_kind = 'timeline'
      AND (mark_in_frame IS NOT NULL OR mark_out_frame IS NOT NULL)
]])
assert(tl_mark_count == 0, string.format(
    "Expected 0 timeline clips with marks, got %d", tl_mark_count))

-- Timeline clips should have default playhead (0)
local tl_playhead_count = scalar([[
    SELECT COUNT(*) FROM clips
    WHERE clip_kind = 'timeline'
      AND playhead_frame != 0
]])
assert(tl_playhead_count == 0, string.format(
    "Expected 0 timeline clips with non-zero playhead, got %d", tl_playhead_count))
print("  OK")

-- ======================================================================
-- Test 3: Master clips with nil marks in fixture have NULL in DB
-- ======================================================================
print("Test 3: Nil marks stay NULL in DB...")
-- All pool_master_clips in the fixture have nil mark_in/mark_out
local marked_count = scalar([[
    SELECT COUNT(*) FROM clips
    WHERE clip_kind = 'master'
      AND (mark_in_frame IS NOT NULL OR mark_out_frame IS NOT NULL)
]])
assert(marked_count == 0, string.format(
    "Expected 0 master clips with marks (fixture has none), got %d", marked_count))
print("  OK")

-- Cleanup
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("✅ test_drp_import_marks.lua passed")
