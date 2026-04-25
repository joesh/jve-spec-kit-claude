#!/usr/bin/env luajit
-- Test resolve_clips_at_playhead helper: selection-aware clip resolution.
--
-- Scenarios:
-- 1. No selection → returns all clips at playhead
-- 2. Selection intersects playhead → returns only selected clips at playhead
-- 3. Selection does NOT intersect playhead → falls back to all clips at playhead
-- 4. No clips at playhead → returns empty list
-- 5. Multiple tracks — clips on different tracks both returned

require('test_env')

local database = require("core.database")
local command_helper = require("core.command_helper")
local timeline_state = require("ui.timeline.timeline_state")
local Clip = require("models.clip")
local test_env = require("test_env")

local DB_PATH = "/tmp/jve/test_resolve_clips_at_playhead.db"
os.remove(DB_PATH)
os.execute("mkdir -p /tmp/jve")
database.init(DB_PATH)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'ResolveTest', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'Seq', 'nested', 25, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
]])
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v2', 'seq', 'V2', 'VIDEO', 2, 1);
]])

-- Create media for clips
test_env.create_test_media({
    id = "media_a", project_id = "proj", name = "A.mov",
    file_path = "/tmp/jve/a.mov", duration_frames = 100,
    fps_numerator = 25, fps_denominator = 1,
})
test_env.create_test_media({
    id = "media_b", project_id = "proj", name = "B.mov",
    file_path = "/tmp/jve/b.mov", duration_frames = 100,
    fps_numerator = 25, fps_denominator = 1,
})
test_env.create_test_media({
    id = "media_c", project_id = "proj", name = "C.mov",
    file_path = "/tmp/jve/c.mov", duration_frames = 100,
    fps_numerator = 25, fps_denominator = 1,
})

-- Clip layout:
--   V1: clip_a [0..50)  clip_c [60..100)
--   V2: clip_b [10..80)
-- Playhead at 30 intersects clip_a and clip_b.
-- Playhead at 55 intersects only clip_b.
-- Playhead at 70 intersects clip_b and clip_c.

local function create_clip(id, track_id, media_id, start_frame, dur)
    local clip = Clip.create({
        name = id,
        id = id,
        track_id = track_id,
        owner_sequence_id = "seq",
        timeline_start_frame = start_frame,
        duration_frames = dur,
        source_in_frame = 0,
        source_out_frame = dur,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
    assert(clip ~= nil and clip ~= "", "failed to save " .. id)
    return clip
end

create_clip("clip_a", "v1", "media_a", 0, 50)
create_clip("clip_b", "v2", "media_b", 10, 70)
create_clip("clip_c", "v1", "media_c", 60, 40)

-- Initialize timeline_state from DB (no mocks)
timeline_state.init("seq", "proj")

local function set_ids(clips)
    local ids = {}
    for _, c in ipairs(clips) do ids[c.id] = true end
    return ids
end

print("=== resolve_clips_at_playhead tests ===\n")

-- 1. No selection, playhead at 30 → clip_a + clip_b
timeline_state.set_selection({})
timeline_state.set_playhead_position(30)
local result, ph = command_helper.resolve_clips_at_playhead()
assert(ph == 30, "playhead should be 30")
assert(#result == 2, string.format("expected 2 clips, got %d", #result))
local ids = set_ids(result)
assert(ids["clip_a"] and ids["clip_b"], "should return clip_a and clip_b")
print("✓ 1. No selection → all clips at playhead")

-- Helper: get clip object from timeline state by ID
local function get_ts_clip(clip_id)
    for _, c in ipairs(timeline_state.get_clips()) do
        if c.id == clip_id then return c end
    end
    error("clip not found in timeline state: " .. clip_id)
end

-- 2. Selection intersects playhead → only selected clip returned
timeline_state.set_selection({get_ts_clip("clip_a")})
timeline_state.set_playhead_position(30)
result, ph = command_helper.resolve_clips_at_playhead()
assert(ph == 30, "playhead should be 30")
assert(#result == 1, string.format("expected 1 clip, got %d", #result))
assert(result[1].id == "clip_a", "should return only clip_a")
print("✓ 2. Selection intersects playhead → selected clip only")

-- 3. Selection does NOT intersect playhead → falls back to all clips
-- Select clip_c (at 60..100), playhead at 30 (clip_c not there)
timeline_state.set_selection({get_ts_clip("clip_c")})
timeline_state.set_playhead_position(30)
result, ph = command_helper.resolve_clips_at_playhead()
assert(ph == 30, "playhead should be 30")
assert(#result == 2, string.format("expected 2 clips (fallback), got %d", #result))
ids = set_ids(result)
assert(ids["clip_a"] and ids["clip_b"], "should fall back to clip_a and clip_b")
print("✓ 3. Selection doesn't intersect → falls back to all clips at playhead")

-- 4. No clips at playhead → empty list (frame 105 is past all clips)
timeline_state.set_selection({})
timeline_state.set_playhead_position(105)
result, ph = command_helper.resolve_clips_at_playhead()
assert(ph == 105, "playhead should be 105")
assert(#result == 0, string.format("expected 0 clips, got %d", #result))
print("✓ 4. No clips at playhead → empty list")

-- 5. Multiple tracks both returned
timeline_state.set_selection({})
timeline_state.set_playhead_position(70)
result, ph = command_helper.resolve_clips_at_playhead()
assert(ph == 70, "playhead should be 70")
assert(#result == 2, string.format("expected 2 clips, got %d", #result))
ids = set_ids(result)
assert(ids["clip_b"] and ids["clip_c"], "should return clip_b (V2) and clip_c (V1)")
print("✓ 5. Multiple tracks — clips on different tracks both returned")

print("\n✅ test_resolve_clips_at_playhead.lua passed")
