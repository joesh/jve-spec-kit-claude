#!/usr/bin/env luajit
-- Test resolve_all_audio_at_time: independent audio resolution for J/L cuts
-- J-cut layout: audio from clip A continues while video switches to clip B

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path
require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")

-- Initialize database
local DB_PATH = "/tmp/jve/test_jl_cut_resolve.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create minimal project/sequence
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq', 'proj', 'TestSeq', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Create tracks: V1, A1, A2
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
          ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0),
          ('a2', 'seq', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Create test media
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_a', 'proj', '/test/clip_a.mov', 'clip_a', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_b', 'proj', '/test/clip_b.mov', 'clip_b', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- J-cut layout:
-- V1: clip_B at frames 48-96 (media_b)
-- A1: clip_A_audio at frames 0-72 (media_a)  ← audio from A extends past video edit point
-- A2: clip_B_audio at frames 48-96 (media_b)
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_v1_b', 'proj', 'timeline', 'ClipB_Video', 'v1', 'media_b', 48, 48, 0, 48, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_a1_a', 'proj', 'timeline', 'ClipA_Audio', 'a1', 'media_a', 0, 72, 0, 72, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_a2_b', 'proj', 'timeline', 'ClipA2_Audio', 'a2', 'media_b', 48, 48, 0, 48, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

local timeline_resolver = require("core.playback.timeline_resolver")

-- Test 1: At frame 60 — video is clip_B, audio is [clip_A on A1, clip_B on A2]
local function test_jl_cut_frame_60()
    local playhead = 60

    -- Video: clip_B on V1 (frames 48-96)
    local video = timeline_resolver.resolve_at_time(playhead, "seq")
    assert(video, "Should have video at frame 60")
    assert(video.clip.id == "clip_v1_b",
        "Video should be clip_B, got " .. tostring(video.clip.id))
    assert(video.media_path == "/test/clip_b.mov",
        "Video media should be clip_b.mov")

    -- Audio: both A1 (clip_A, frames 0-72) and A2 (clip_B, frames 48-96)
    local audio = timeline_resolver.resolve_all_audio_at_time(playhead, "seq")
    assert(#audio == 2,
        string.format("Should have 2 audio clips at frame 60, got %d", #audio))

    -- A1 has lower track_index, should come first (sorted by track_index ASC)
    assert(audio[1].clip.id == "clip_a1_a",
        "First audio clip should be clip_A on A1, got " .. tostring(audio[1].clip.id))
    assert(audio[1].media_path == "/test/clip_a.mov",
        "A1 media should be clip_a.mov")
    assert(audio[1].track.id == "a1",
        "First audio should be on track a1")

    assert(audio[2].clip.id == "clip_a2_b",
        "Second audio clip should be clip_B on A2, got " .. tostring(audio[2].clip.id))
    assert(audio[2].media_path == "/test/clip_b.mov",
        "A2 media should be clip_b.mov")
    assert(audio[2].track.id == "a2",
        "Second audio should be on track a2")

    -- Verify source times
    -- A1 clip_A: timeline_start=0, source_in=0, at frame 60 → source_frame=60
    local expected_a1_us = math.floor(60 * 1000000 / 24)
    assert(math.abs(audio[1].source_time_us - expected_a1_us) < 1000,
        string.format("A1 source_time should be ~%d, got %d", expected_a1_us, audio[1].source_time_us))

    -- A2 clip_B: timeline_start=48, source_in=0, at frame 60 → source_frame=12
    local expected_a2_us = math.floor(12 * 1000000 / 24)
    assert(math.abs(audio[2].source_time_us - expected_a2_us) < 1000,
        string.format("A2 source_time should be ~%d, got %d", expected_a2_us, audio[2].source_time_us))

    print("✅ test_jl_cut_frame_60 passed")
end

-- Test 2: At frame 30 — only A1 has audio (clip_A, frames 0-72)
local function test_only_a1_at_frame_30()
    local playhead = 30

    -- No video at frame 30 (V1 clip_B starts at 48)
    local video = timeline_resolver.resolve_at_time(playhead, "seq")
    assert(video == nil, "Should have no video at frame 30")

    -- Audio: only A1 (clip_A, frames 0-72), A2 clip starts at 48
    local audio = timeline_resolver.resolve_all_audio_at_time(playhead, "seq")
    assert(#audio == 1,
        string.format("Should have 1 audio clip at frame 30, got %d", #audio))
    assert(audio[1].clip.id == "clip_a1_a",
        "Audio should be clip_A on A1, got " .. tostring(audio[1].clip.id))
    assert(audio[1].media_path == "/test/clip_a.mov")

    print("✅ test_only_a1_at_frame_30 passed")
end

-- Test 3: At frame 100 — gap, no audio anywhere
local function test_gap_returns_empty()
    local playhead = 100

    local audio = timeline_resolver.resolve_all_audio_at_time(playhead, "seq")
    assert(#audio == 0,
        string.format("Should have 0 audio clips at frame 100, got %d", #audio))

    print("✅ test_gap_returns_empty passed")
end

-- Test 4: At frame 48 — edit point: A1 still playing, A2 just starts
local function test_edit_point_frame_48()
    local playhead = 48

    local audio = timeline_resolver.resolve_all_audio_at_time(playhead, "seq")
    assert(#audio == 2,
        string.format("Should have 2 audio clips at frame 48, got %d", #audio))

    -- A1 clip_A still playing (frames 0-72 covers 48)
    assert(audio[1].clip.id == "clip_a1_a")
    -- A2 clip_B starts exactly at 48
    assert(audio[2].clip.id == "clip_a2_b")

    print("✅ test_edit_point_frame_48 passed")
end

-- Test 5: Track metadata is returned (needed for mute/solo logic)
local function test_track_metadata_returned()
    local playhead = 60
    local audio = timeline_resolver.resolve_all_audio_at_time(playhead, "seq")

    for _, entry in ipairs(audio) do
        assert(entry.track, "track must be present in result")
        assert(entry.track.id, "track.id must be present")
        assert(entry.track.volume ~= nil, "track.volume must be present")
        assert(entry.track.muted ~= nil, "track.muted must be present")
        assert(entry.track.soloed ~= nil, "track.soloed must be present")
    end

    print("✅ test_track_metadata_returned passed")
end

-- Run all tests
test_jl_cut_frame_60()
test_only_a1_at_frame_30()
test_gap_returns_empty()
test_edit_point_frame_48()
test_track_metadata_returned()

print("✅ test_jl_cut_resolve.lua passed")
