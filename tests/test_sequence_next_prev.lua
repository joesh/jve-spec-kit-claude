#!/usr/bin/env luajit
-- TDD test: Sequence:get_next_video/audio and get_prev_video/audio
-- Returns the same entry format as get_video_at/get_audio_at but for the
-- next/prev clip on each track relative to a boundary frame.

require('test_env')

print("=== test_sequence_next_prev.lua ===")

local database = require("core.database")
local import_schema = require("import_schema")
local Sequence = require("models.sequence")

-- Initialize database
local DB_PATH = "/tmp/jve/test_sequence_next_prev.db"
os.remove(DB_PATH)
os.remove(DB_PATH .. "-wal")
os.remove(DB_PATH .. "-shm")
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Project + sequence
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'Test', strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq', 'proj', 'Timeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Two video tracks, one audio track
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
          ('v2', 'seq', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0),
          ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Test media
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_v', 'proj', '/test/v.mov', 'v', 200, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_a', 'proj', '/test/a.wav', 'a', 960000, 48000, 1, 0, 0, 2, 'pcm',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- V1: clip_v1a [0, 100), clip_v1b [200, 300)
-- V2: clip_v2a [50, 150)
-- A1: clip_a1 [0, 100), clip_a2 [200, 300)
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_v1a', 'proj', 'timeline', 'V1a', 'v1', 'media_v', 0,   100, 0,   100, 24, 1, 1, 0, strftime('%s','now'), strftime('%s','now')),
        ('clip_v1b', 'proj', 'timeline', 'V1b', 'v1', 'media_v', 200, 100, 0,   100, 24, 1, 1, 0, strftime('%s','now'), strftime('%s','now')),
        ('clip_v2a', 'proj', 'timeline', 'V2a', 'v2', 'media_v', 50,  100, 10,  110, 24, 1, 1, 0, strftime('%s','now'), strftime('%s','now')),
        ('clip_a1',  'proj', 'timeline', 'A1',  'a1', 'media_a', 0,   100, 0,   200000, 48000, 1, 1, 0, strftime('%s','now'), strftime('%s','now')),
        ('clip_a2',  'proj', 'timeline', 'A2',  'a1', 'media_a', 200, 100, 200000, 400000, 48000, 1, 1, 0, strftime('%s','now'), strftime('%s','now'))
]]))

local seq = Sequence.load("seq")
assert(seq, "Failed to load test sequence")

--------------------------------------------------------------------------------
-- get_next_video
--------------------------------------------------------------------------------

print("\n--- get_next_video: finds next on each video track ---")
do
    -- After clip_v1a ends at frame 100, next on V1 is clip_v1b at 200
    -- After frame 100, V2's clip_v2a also starts at 50 (already past), no next
    -- But clip_v2a ends at 150, so if boundary is at 150, no next on V2
    local results = seq:get_next_video(100)
    assert(type(results) == "table", "get_next_video must return table")
    -- Should have at least clip_v1b (on V1)
    local found_v1b = false
    for _, entry in ipairs(results) do
        assert(entry.clip, "Entry must have clip")
        assert(entry.media_path, "Entry must have media_path")
        assert(entry.source_frame ~= nil, "Entry must have source_frame")
        assert(entry.track, "Entry must have track")
        if entry.clip.id == 'clip_v1b' then found_v1b = true end
    end
    assert(found_v1b, "Expected clip_v1b in next_video results after frame 100")
    print("  get_next_video finds clips across tracks passed")
end

print("\n--- get_next_video: empty at end ---")
do
    local results = seq:get_next_video(500)
    assert(type(results) == "table", "get_next_video must return table")
    assert(#results == 0, string.format(
        "Expected empty at frame 500, got %d entries", #results))
    print("  get_next_video returns empty at end passed")
end

print("\n--- get_next_video: asserts on non-number ---")
do
    local ok, err = pcall(seq.get_next_video, seq, "abc")
    assert(not ok, "Should assert on non-number")
    assert(err:find("after_frame"), "Error should mention after_frame")
    print("  get_next_video asserts on non-number passed")
end

--------------------------------------------------------------------------------
-- get_prev_video
--------------------------------------------------------------------------------

print("\n--- get_prev_video: finds prev on each video track ---")
do
    -- Before frame 200 (start of clip_v1b):
    -- V1: clip_v1a ends at 100 <= 200 ✓
    -- V2: clip_v2a ends at 150 <= 200 ✓
    local results = seq:get_prev_video(200)
    assert(type(results) == "table", "get_prev_video must return table")
    local found_v1a = false
    local found_v2a = false
    for _, entry in ipairs(results) do
        if entry.clip.id == 'clip_v1a' then found_v1a = true end
        if entry.clip.id == 'clip_v2a' then found_v2a = true end
    end
    assert(found_v1a, "Expected clip_v1a in prev_video before frame 200")
    assert(found_v2a, "Expected clip_v2a in prev_video before frame 200")
    print("  get_prev_video finds clips across tracks passed")
end

print("\n--- get_prev_video: empty at start ---")
do
    local results = seq:get_prev_video(0)
    assert(#results == 0, "Expected empty at frame 0")
    print("  get_prev_video returns empty at start passed")
end

--------------------------------------------------------------------------------
-- get_next_audio / get_prev_audio
--------------------------------------------------------------------------------

print("\n--- get_next_audio: finds next audio clip ---")
do
    local results = seq:get_next_audio(100)
    assert(#results >= 1, "Expected at least 1 next audio clip")
    assert(results[1].clip.id == 'clip_a2', string.format(
        "Expected clip_a2, got %s", tostring(results[1].clip.id)))
    print("  get_next_audio finds next audio clip passed")
end

print("\n--- get_prev_audio: finds prev audio clip ---")
do
    local results = seq:get_prev_audio(200)
    assert(#results >= 1, "Expected at least 1 prev audio clip")
    assert(results[1].clip.id == 'clip_a1', string.format(
        "Expected clip_a1, got %s", tostring(results[1].clip.id)))
    print("  get_prev_audio finds prev audio clip passed")
end

--------------------------------------------------------------------------------
-- Entry format matches get_video_at / get_audio_at
--------------------------------------------------------------------------------

print("\n--- entry format: matches get_video_at ---")
do
    local results = seq:get_next_video(100)
    for _, entry in ipairs(results) do
        assert(entry.media_path, "Entry missing media_path")
        assert(type(entry.source_time_us) == "number", "Entry missing source_time_us")
        assert(type(entry.source_frame) == "number", "Entry missing source_frame")
        assert(entry.clip, "Entry missing clip")
        assert(entry.track, "Entry missing track")
        -- source_frame = source_in + 0 (clip start)
        assert(entry.source_frame == entry.clip.source_in,
            "source_frame at clip start should equal source_in")
    end
    print("  entry format matches get_video_at passed")
end

print("\n--- get_prev_video: source_frame at clip END (for reverse pre-buffer) ---")
do
    -- get_prev_video should return source position at the LAST frame of the clip,
    -- not the first — reverse playback enters a clip at its end.
    local results = seq:get_prev_video(200)
    for _, entry in ipairs(results) do
        -- Last timeline frame of clip = timeline_start + duration - 1
        -- source at last frame = source_in + (duration - 1)
        local expected_source_frame = entry.clip.source_in + entry.clip.duration - 1
        assert(entry.source_frame == expected_source_frame, string.format(
            "get_prev_video: clip %s source_frame should be %d (clip end), got %d",
            entry.clip.id, expected_source_frame, entry.source_frame))
    end
    print("  get_prev_video returns source_frame at clip end passed")
end

print("\n--- get_prev_audio: source_frame at clip END ---")
do
    local results = seq:get_prev_audio(200)
    for _, entry in ipairs(results) do
        local expected_source_frame = entry.clip.source_in + entry.clip.duration - 1
        assert(entry.source_frame == expected_source_frame, string.format(
            "get_prev_audio: clip %s source_frame should be %d (clip end), got %d",
            entry.clip.id, expected_source_frame, entry.source_frame))
    end
    print("  get_prev_audio returns source_frame at clip end passed")
end

print("\n✅ test_sequence_next_prev.lua passed")
