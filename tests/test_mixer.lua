#!/usr/bin/env luajit
-- Test Mixer module: audio source resolution and source list building.
-- The resolve_audio_sources() function uses real DB; mix_sources() requires
-- C++ bindings (tested via integration tests in the app).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path
require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")
local Sequence = require("models.sequence")

-- Initialize database
local DB_PATH = "/tmp/jve/test_mixer.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create project + sequence at 24fps
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq', 'proj', 'TestTimeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Audio tracks: A1 (normal), A2 (muted), A3 (soloed)
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 0.8, 0.0),
          ('a2', 'seq', 'A2', 'AUDIO', 2, 1, 0, 1, 0, 1.0, 0.0),
          ('a3', 'seq', 'A3', 'AUDIO', 3, 1, 0, 0, 0, 0.5, 0.0)
]]))

-- Media: standard A/V file + audio-only file
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_av', 'proj', '/test/video.mov', 'video', 240, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_wav', 'proj', '/test/audio.wav', 'audio', 480000, 48000, 1, 0, 0, 2, 'pcm',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Audio clips:
-- A1: frames 0-96, uses media_av (24fps source)
-- A2: frames 0-96, uses media_wav (48000 sample rate), MUTED
-- A3: frames 48-144, uses media_wav
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_a1', 'proj', 'timeline', 'ClipA1', 'a1', 'media_av', 0, 96, 0, 96, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_a2', 'proj', 'timeline', 'ClipA2', 'a2', 'media_wav', 0, 96, 0, 96000, 48000, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_a3', 'proj', 'timeline', 'ClipA3', 'a3', 'media_wav', 48, 96, 0, 96000, 48000, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

local seq = Sequence.load("seq")
assert(seq, "Failed to load test sequence")

-- Mock media_cache with minimal ensure_audio_pooled
local mock_media_cache = {
    ensure_audio_pooled = function(path)
        return {
            has_audio = true,
            audio_sample_rate = 48000,
            audio_channels = 2,
            duration_us = 10000000,  -- 10 seconds
            start_tc = 0,
        }
    end,
}

local mixer = require("core.mixer")

-- ============================================================================
-- Test resolve_audio_sources
-- ============================================================================

local function test_resolve_basic()
    -- Frame 10: A1 and A2 active (A3 starts at 48)
    local sources, clip_ids = mixer.resolve_audio_sources(
        seq, 10, 24, 1, mock_media_cache)

    assert(#sources == 2, string.format("Expected 2 sources at frame 10, got %d", #sources))
    assert(clip_ids["clip_a1"], "Expected clip_a1 in IDs")
    assert(clip_ids["clip_a2"], "Expected clip_a2 in IDs")
    print("  test_resolve_basic passed")
end

local function test_resolve_muted_volume()
    -- A2 is muted, should have volume=0
    local sources = mixer.resolve_audio_sources(
        seq, 10, 24, 1, mock_media_cache)

    local a1_src, a2_src
    for _, s in ipairs(sources) do
        if s.clip_id == "clip_a1" then a1_src = s end
        if s.clip_id == "clip_a2" then a2_src = s end
    end
    assert(a1_src, "clip_a1 source not found")
    assert(a2_src, "clip_a2 source not found")

    -- A1: not muted, track volume = 0.8
    assert(a1_src.volume == 0.8,
        string.format("Expected a1 volume=0.8, got %s", tostring(a1_src.volume)))
    -- A2: muted → volume=0
    assert(a2_src.volume == 0,
        string.format("Expected a2 volume=0 (muted), got %s", tostring(a2_src.volume)))
    print("  test_resolve_muted_volume passed")
end

local function test_resolve_multi_track()
    -- Frame 60: all three tracks active (A1: 0-96, A2: 0-96, A3: 48-144)
    local sources, clip_ids = mixer.resolve_audio_sources(
        seq, 60, 24, 1, mock_media_cache)

    assert(#sources == 3, string.format("Expected 3 sources at frame 60, got %d", #sources))
    assert(clip_ids["clip_a1"], "Expected clip_a1")
    assert(clip_ids["clip_a2"], "Expected clip_a2")
    assert(clip_ids["clip_a3"], "Expected clip_a3")
    print("  test_resolve_multi_track passed")
end

local function test_resolve_gap()
    -- Frame 200: no clips
    local sources, clip_ids = mixer.resolve_audio_sources(
        seq, 200, 24, 1, mock_media_cache)

    assert(#sources == 0, "Expected 0 sources at gap frame 200")
    local count = 0
    for _ in pairs(clip_ids) do count = count + 1 end
    assert(count == 0, "Expected empty clip_ids at gap")
    print("  test_resolve_gap passed")
end

local function test_resolve_source_offset()
    -- A1 clip: timeline_start=0, source_in=0, clip rate=24fps
    -- At frame 10: seek_us = 0, timeline_start_us = 0
    -- No conform needed (media fps = 24 = seq fps = 24)
    -- source_offset_us = timeline_start_us - seek_us = 0 - 0 = 0
    local sources = mixer.resolve_audio_sources(
        seq, 10, 24, 1, mock_media_cache)

    local a1_src
    for _, s in ipairs(sources) do
        if s.clip_id == "clip_a1" then a1_src = s end
    end
    assert(a1_src, "clip_a1 source not found")
    assert(a1_src.source_offset_us == 0,
        string.format("Expected source_offset=0 for a1, got %d", a1_src.source_offset_us))
    print("  test_resolve_source_offset passed")
end

local function test_resolve_clip_end()
    -- A1 clip: timeline_start=0, duration=96 frames at 24fps
    -- clip_end_us = (0 + 96) * 1000000 * 1 / 24 = 4000000 us = 4 seconds
    local sources = mixer.resolve_audio_sources(
        seq, 10, 24, 1, mock_media_cache)

    local a1_src
    for _, s in ipairs(sources) do
        if s.clip_id == "clip_a1" then a1_src = s end
    end
    assert(a1_src, "clip_a1 source not found")
    local expected_end = math.floor(96 * 1000000 / 24)
    assert(a1_src.clip_end_us == expected_end,
        string.format("Expected clip_end=%d, got %d", expected_end, a1_src.clip_end_us))
    print("  test_resolve_clip_end passed")
end

-- ============================================================================
-- Test solo behavior
-- ============================================================================

local function test_resolve_solo()
    -- Set A3 to soloed via DB update
    assert(db:exec("UPDATE tracks SET soloed = 1 WHERE id = 'a3'"))

    -- Frame 60: all three tracks, but A3 is soloed
    -- Need to reload sequence to pick up track changes
    -- (Track.find_by_sequence reads from DB each time)
    local sources = mixer.resolve_audio_sources(
        seq, 60, 24, 1, mock_media_cache)

    -- A3 is soloed: only A3 should have volume > 0
    local volumes = {}
    for _, s in ipairs(sources) do
        volumes[s.clip_id] = s.volume
    end

    assert(volumes["clip_a3"] == 0.5,
        string.format("Soloed A3 should have volume 0.5, got %s", tostring(volumes["clip_a3"])))
    assert(volumes["clip_a1"] == 0,
        string.format("Non-soloed A1 should have volume 0, got %s", tostring(volumes["clip_a1"])))
    assert(volumes["clip_a2"] == 0,
        string.format("Non-soloed A2 should have volume 0, got %s", tostring(volumes["clip_a2"])))

    -- Reset solo
    assert(db:exec("UPDATE tracks SET soloed = 0 WHERE id = 'a3'"))

    print("  test_resolve_solo passed")
end

-- ============================================================================
-- Run all tests
-- ============================================================================

print("Testing mixer.resolve_audio_sources()...")
test_resolve_basic()
test_resolve_muted_volume()
test_resolve_multi_track()
test_resolve_gap()
test_resolve_source_offset()
test_resolve_clip_end()
test_resolve_solo()

print("✅ test_mixer.lua passed")
