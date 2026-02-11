#!/usr/bin/env luajit

-- Test: snapshot_manager uses integer coords and validates required fields
-- Updated for integer-based coordinates (rational refactor complete)

local test_env = require("test_env")
local expect_error = test_env.expect_error
local assert_type = test_env.assert_type
local raw_sql = test_env.raw_sql

local database = require("core.database")
local snapshot_manager = require("core.snapshot_manager")
local json = require("dkjson")

local db_path = "/tmp/jve/test_snapshot_integer.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()

print("=== Snapshot Manager Integer Coords Tests ===")

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Timeline 1', 'timeline', 24, 1, 48000,
        1920, 1080, 0, 240, 10, '[]', '[]', %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'shot_01.mov', '/tmp/shot_01.mov', 1000,
        24, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now))

--------------------------------------------------------------------------------
-- HAPPY PATH: Integer coordinates round-trip
--------------------------------------------------------------------------------

print("Test 1: create_snapshot with integer coords")
local clips = {
    {
        id = "clip1",
        clip_kind = "timeline",
        name = "My Clip",
        project_id = "proj1",
        track_id = "trk1",
        owner_sequence_id = "seq1",
        parent_clip_id = nil,
        master_clip_id = nil,
        media_id = "med1",
        -- INTEGER coordinates (post-refactor)
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        rate = { fps_numerator = 24, fps_denominator = 1 },
        enabled = true,
        offline = false,
    },
}

local ok = snapshot_manager.create_snapshot(db, "seq1", 50, clips)
assert(ok == true, "create_snapshot should return true")
print("  ✓ create_snapshot succeeded with integer coords")

print("Test 2: load_snapshot returns integer coords")
local snap = snapshot_manager.load_snapshot(db, "seq1")
assert(snap ~= nil, "load_snapshot should not return nil")
assert(#snap.clips == 1, "should have 1 clip")

local c = snap.clips[1]
assert_type(c.timeline_start, "number", "clip.timeline_start")
assert(c.timeline_start == 0, "timeline_start should be 0, got " .. tostring(c.timeline_start))
print("  ✓ timeline_start is integer 0")

assert_type(c.duration, "number", "clip.duration")
assert(c.duration == 100, "duration should be 100, got " .. tostring(c.duration))
print("  ✓ duration is integer 100")

assert_type(c.source_in, "number", "clip.source_in")
assert(c.source_in == 0, "source_in should be 0, got " .. tostring(c.source_in))
print("  ✓ source_in is integer 0")

assert_type(c.source_out, "number", "clip.source_out")
assert(c.source_out == 100, "source_out should be 100, got " .. tostring(c.source_out))
print("  ✓ source_out is integer 100")

print("Test 3: media duration is integer")
assert(#snap.media == 1, "should have 1 media")
local m = snap.media[1]
assert_type(m.duration, "number", "media.duration")
assert(m.duration == 1000, "media duration should be 1000, got " .. tostring(m.duration))
print("  ✓ media duration is integer 1000")

print("Test 4: fps metadata preserved in rate field")
assert(c.rate, "clip should have rate")
assert(c.rate.fps_numerator == 24, "rate.fps_numerator should be 24")
assert(c.rate.fps_denominator == 1, "rate.fps_denominator should be 1")
print("  ✓ rate metadata preserved")

--------------------------------------------------------------------------------
-- ERROR PATH: Missing required integer fields
--------------------------------------------------------------------------------

print("Test 5: deserialize asserts on missing timeline_start_frame")
-- Delete the valid snapshot first so corrupt one is loaded
db:exec("DELETE FROM snapshots WHERE sequence_id = 'seq1'")

-- Create corrupt snapshot payload with missing field
local bad_payload = json.encode({
    sequence = {
        id = "seq1", project_id = "proj1", name = "T", kind = "timeline",
        fps_numerator = 24, fps_denominator = 1, audio_rate = 48000,
        width = 1920, height = 1080,
        view_start_frame = 0, view_duration_frames = 240, playhead_frame = 0,
    },
    tracks = {},
    clips = {
        {
            id = "clip_bad", clip_kind = "timeline", name = "Bad",
            project_id = "proj1", track_id = "trk1", owner_sequence_id = "seq1",
            -- Missing timeline_start_frame!
            duration_frames = 100,
            source_in_frame = 0, source_out_frame = 100,
            fps_numerator = 24, fps_denominator = 1,
            enabled = 1, offline = 0,
        },
    },
    media = {},
})

-- Insert corrupt snapshot - escape JSON for SQL
local escaped_payload = bad_payload:gsub("'", "''")
raw_sql(db, "INSERT OR REPLACE INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at) VALUES ('snap_bad', 'seq1', 999, '%s', %d)", escaped_payload, now)

expect_error(function()
    snapshot_manager.load_snapshot(db, "seq1")
end, "timeline_start_frame")
print("  ✓ deserialize asserts on missing timeline_start_frame")

print("Test 6: deserialize asserts on missing duration_frames")
-- Clean slate for this test
db:exec("DELETE FROM snapshots WHERE sequence_id = 'seq1'")

local bad_payload2 = json.encode({
    sequence = {
        id = "seq1", project_id = "proj1", name = "T", kind = "timeline",
        fps_numerator = 24, fps_denominator = 1, audio_rate = 48000,
        width = 1920, height = 1080,
        view_start_frame = 0, view_duration_frames = 240, playhead_frame = 0,
    },
    tracks = {},
    clips = {
        {
            id = "clip_no_dur", clip_kind = "timeline", name = "No Duration",
            project_id = "proj1", track_id = "trk1", owner_sequence_id = "seq1",
            timeline_start_frame = 0,
            -- Missing duration_frames!
            source_in_frame = 0, source_out_frame = 100,
            fps_numerator = 24, fps_denominator = 1,
            enabled = 1, offline = 0,
        },
    },
    media = {},
})

local escaped_payload2 = bad_payload2:gsub("'", "''")
raw_sql(db, "INSERT OR REPLACE INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at) VALUES ('snap_bad2', 'seq1', 998, '%s', %d)", escaped_payload2, now)

expect_error(function()
    snapshot_manager.load_snapshot(db, "seq1")
end, "duration_frames")
print("  ✓ deserialize asserts on missing duration_frames")

print("✅ test_snapshot_manager_integer_coords.lua passed")
