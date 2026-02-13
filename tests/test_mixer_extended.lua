--- Extended Mixer tests: behaviors migrated from old timeline_resolver tests.
--
-- Covers gaps not in test_mixer.lua:
-- - J-cut multi-clip audio resolution (video ≠ audio at same frame)
-- - Mixed-fps audio conform (23.976fps source on 24fps timeline)
-- - Audio clip duration with source_in > 0 (offset computation)

require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")
local Sequence = require("models.sequence")

-- Initialize database
local DB_PATH = "/tmp/jve/test_mixer_extended.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create project
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

--------------------------------------------------------------------------------
-- Mock media_cache
--------------------------------------------------------------------------------

local mock_media_cache = {
    ensure_audio_pooled = function(path)
        return {
            has_audio = true,
            audio_sample_rate = 48000,
            audio_channels = 2,
            duration_us = 20000000,
            start_tc = 0,
        }
    end,
}

local mixer = require("core.mixer")

--------------------------------------------------------------------------------
-- Test 1: J-cut multi-clip audio resolution
--
-- Layout:
--   V1: clip_v (video)  frames 0-96
--   A1: clip_a1 (audio) frames 0-72  (audio extends beyond video)
--   A2: clip_a2 (audio) frames 48-96 (overlaps A1, starts before video ends)
--
-- At frame 60: video=clip_v, audio=[clip_a1, clip_a2]
-- At frame 30: video=clip_v, audio=[clip_a1 only]
-- At frame 100: gap, no audio
-- At frame 48: edit point, both A1 and A2 present
--------------------------------------------------------------------------------
print("\n--- J-cut: multi-clip audio resolution ---")
do
    -- Create J-cut sequence
    assert(db:exec([[
        INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                             audio_rate, width, height, view_start_frame, view_duration_frames,
                             playhead_frame, created_at, modified_at)
        VALUES('jcut_seq', 'proj', 'JCutTimeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
               strftime('%s','now'), strftime('%s','now'))
    ]]))

    assert(db:exec([[
        INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES('jv1', 'jcut_seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
              ('ja1', 'jcut_seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 0.8, 0.0),
              ('ja2', 'jcut_seq', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 0.6, 0.0)
    ]]))

    assert(db:exec([[
        INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                         width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES('jmedia_v', 'proj', '/test/jcut_video.mov', 'jcut_video', 200, 24, 1, 1920, 1080, 2, 'h264',
               strftime('%s','now'), strftime('%s','now'), '{}'),
              ('jmedia_a', 'proj', '/test/jcut_audio.wav', 'jcut_audio', 480000, 48000, 1, 0, 0, 2, 'pcm',
               strftime('%s','now'), strftime('%s','now'), '{}')
    ]]))

    -- A1: frames 0-72 on track A1 (audio extends past typical video cut)
    -- A2: frames 48-96 on track A2 (audio starts before A1 ends → overlap)
    assert(db:exec([[
        INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                         timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                         fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES('jclip_a1', 'proj', 'timeline', 'JClipA1', 'ja1', 'jmedia_a', 0, 72, 0, 72000, 48000, 1, 1, 0,
               strftime('%s','now'), strftime('%s','now')),
              ('jclip_a2', 'proj', 'timeline', 'JClipA2', 'ja2', 'jmedia_v', 48, 48, 48, 96, 24, 1, 1, 0,
               strftime('%s','now'), strftime('%s','now'))
    ]]))

    local seq = Sequence.load("jcut_seq")
    assert(seq, "Failed to load J-cut sequence")

    -- Frame 60: both A1 (0-72) and A2 (48-96) active
    local sources60, ids60 = mixer.resolve_audio_sources(seq, 60, 24, 1, mock_media_cache)
    assert(#sources60 == 2, string.format("Frame 60: expected 2 sources, got %d", #sources60))
    assert(ids60["jclip_a1"], "Frame 60: expected jclip_a1")
    assert(ids60["jclip_a2"], "Frame 60: expected jclip_a2")

    -- Verify volume from track metadata
    local vols = {}
    for _, s in ipairs(sources60) do vols[s.clip_id] = s.volume end
    assert(vols["jclip_a1"] == 0.8, string.format("A1 volume should be 0.8, got %s", tostring(vols["jclip_a1"])))
    assert(vols["jclip_a2"] == 0.6, string.format("A2 volume should be 0.6, got %s", tostring(vols["jclip_a2"])))

    print("  frame 60: both J-cut clips present with correct volumes")

    -- Frame 30: only A1 active (A2 starts at 48)
    local sources30, ids30 = mixer.resolve_audio_sources(seq, 30, 24, 1, mock_media_cache)
    assert(#sources30 == 1, string.format("Frame 30: expected 1 source, got %d", #sources30))
    assert(ids30["jclip_a1"], "Frame 30: expected only jclip_a1")

    print("  frame 30: only A1 (A2 not yet started)")

    -- Frame 100: gap (A1 ends at 72, A2 ends at 96)
    local sources100, ids100 = mixer.resolve_audio_sources(seq, 100, 24, 1, mock_media_cache)
    assert(#sources100 == 0, "Frame 100: expected 0 sources (gap)")

    print("  frame 100: gap, no audio")

    -- Frame 48: edit point where A2 starts
    local sources48, ids48 = mixer.resolve_audio_sources(seq, 48, 24, 1, mock_media_cache)
    assert(#sources48 == 2, string.format("Frame 48: expected 2 sources, got %d", #sources48))
    assert(ids48["jclip_a1"] and ids48["jclip_a2"], "Frame 48: both clips at edit point")

    print("  frame 48: both clips at A2 edit point")
    print("  J-cut resolution passed")
end

--------------------------------------------------------------------------------
-- Test 2: Mixed-fps audio conform
--
-- 23.976fps source on 24fps timeline.
-- Audio must conform to "frames are frames" speed difference.
--------------------------------------------------------------------------------
print("\n--- mixed-fps: audio conform offset ---")
do
    assert(db:exec([[
        INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                             audio_rate, width, height, view_start_frame, view_duration_frames,
                             playhead_frame, created_at, modified_at)
        VALUES('conform_seq', 'proj', 'ConformTimeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
               strftime('%s','now'), strftime('%s','now'))
    ]]))

    assert(db:exec([[
        INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES('ca1', 'conform_seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0)
    ]]))

    -- 23.976fps media (23976/1000): common NTSC rate
    assert(db:exec([[
        INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                         width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES('cmedia', 'proj', '/test/conform.mov', 'conform', 2400, 24000, 1001, 1920, 1080, 2, 'h264',
               strftime('%s','now'), strftime('%s','now'), '{}')
    ]]))

    -- Audio clip at frames 0-240 using 23.976fps media
    assert(db:exec([[
        INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                         timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                         fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES('cclip', 'proj', 'timeline', 'ConformClip', 'ca1', 'cmedia', 0, 240, 0, 240, 24000, 1001, 1, 0,
               strftime('%s','now'), strftime('%s','now'))
    ]]))

    local seq = Sequence.load("conform_seq")
    assert(seq, "Failed to load conform sequence")

    -- Mock media_cache that returns media fps
    local conform_cache = {
        ensure_audio_pooled = function(path)
            return {
                has_audio = true,
                audio_sample_rate = 48000,
                audio_channels = 2,
                duration_us = 20000000,
                start_tc = 0,
            }
        end,
    }

    -- Frame 0: source_offset should be 0 at start
    local sources0 = mixer.resolve_audio_sources(seq, 0, 24, 1, conform_cache)
    assert(#sources0 == 1, "Frame 0: expected 1 source")
    assert(sources0[1].source_offset_us == 0,
        string.format("Frame 0: source_offset should be 0, got %d", sources0[1].source_offset_us))

    print("  frame 0: source_offset=0 at start")

    -- Frame 120: halfway through. With conform, the offset grows because
    -- the source plays at 23.976fps but the timeline ticks at 24fps.
    -- Conform makes the audio play slightly faster (24/23.976 = 1.001 ratio).
    local sources120 = mixer.resolve_audio_sources(seq, 120, 24, 1, conform_cache)
    assert(#sources120 == 1, "Frame 120: expected 1 source")
    local offset120 = sources120[1].source_offset_us

    -- Without conform (same fps): offset = timeline_start_us - seek_us = 0 - 0 = 0
    -- With conform: offset = playhead_time - conform_source_time
    -- playhead_time = 120 * 1e6 / 24 = 5000000
    -- seek_us = 0 (source_in=0, start_tc=0)
    -- offset_tl = 120 - 0 = 120
    -- conform_source_time = 0 + 120 * 1e6 * 1001 / 24000 = 5005000
    -- offset = 5000000 - 5005000 = -5000
    local playhead_time = math.floor(120 * 1000000 / 24)
    local conform_source_time = math.floor(120 * 1000000 * 1001 / 24000)
    local expected_offset = playhead_time - conform_source_time

    assert(math.abs(offset120 - expected_offset) <= 1,
        string.format("Frame 120: conform offset expected ~%d, got %d",
            expected_offset, offset120))

    print(string.format("  frame 120: conform offset=%d (expected %d)", offset120, expected_offset))

    -- Same-fps clip: offset should be simple (no conform)
    -- Verify by creating a 24fps clip and checking offset stays 0
    assert(db:exec([[
        INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                         width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES('cmedia24', 'proj', '/test/same_fps.mov', 'same_fps', 2400, 24, 1, 1920, 1080, 2, 'h264',
               strftime('%s','now'), strftime('%s','now'), '{}')
    ]]))

    assert(db:exec([[
        INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES('ca2', 'conform_seq', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0)
    ]]))

    assert(db:exec([[
        INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                         timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                         fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES('cclip24', 'proj', 'timeline', 'SameFpsClip', 'ca2', 'cmedia24', 0, 240, 0, 240, 24, 1, 1, 0,
               strftime('%s','now'), strftime('%s','now'))
    ]]))

    -- Reload sequence to pick up new clip
    seq = Sequence.load("conform_seq")
    local sources120b = mixer.resolve_audio_sources(seq, 120, 24, 1, conform_cache)
    -- Find the 24fps clip
    local same_fps_src
    for _, s in ipairs(sources120b) do
        if s.clip_id == "cclip24" then same_fps_src = s end
    end
    assert(same_fps_src, "Should find same-fps clip")
    assert(same_fps_src.source_offset_us == 0,
        string.format("Same-fps clip: offset should be 0, got %d", same_fps_src.source_offset_us))

    print("  same-fps clip: offset=0 (no conform needed)")
    print("  mixed-fps conform passed")
end

--------------------------------------------------------------------------------
-- Test 3: Audio clip duration with source_in > 0
--
-- Regression: duration_us was computed as source_out/rate, not
-- (source_out - source_in)/rate. With source_in > 0, this over-fetches.
--------------------------------------------------------------------------------
print("\n--- source_in > 0: duration = source_out - source_in ---")
do
    assert(db:exec([[
        INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                             audio_rate, width, height, view_start_frame, view_duration_frames,
                             playhead_frame, created_at, modified_at)
        VALUES('srcin_seq', 'proj', 'SrcInTimeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
               strftime('%s','now'), strftime('%s','now'))
    ]]))

    assert(db:exec([[
        INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
        VALUES('sa1', 'srcin_seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0)
    ]]))

    assert(db:exec([[
        INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                         width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES('smedia', 'proj', '/test/srcin.wav', 'srcin', 480000, 48000, 1, 0, 0, 2, 'pcm',
               strftime('%s','now'), strftime('%s','now'), '{}')
    ]]))

    -- Audio clip with source_in > 0:
    -- source_in = 48000 samples (1 second into file)
    -- source_out = 240000 samples (5 seconds into file)
    -- duration = 240000 - 48000 = 192000 samples = 4 seconds
    -- At 48000 sample rate: clip_duration = (240000-48000)/48000 = 4 seconds
    -- timeline_start = 24 (1 second into timeline at 24fps)
    -- duration_frames = 96 (4 seconds at 24fps)
    assert(db:exec([[
        INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                         timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                         fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES('sclip', 'proj', 'timeline', 'SrcInClip', 'sa1', 'smedia', 24, 96, 48000, 240000, 48000, 1, 1, 0,
               strftime('%s','now'), strftime('%s','now'))
    ]]))

    local seq = Sequence.load("srcin_seq")
    assert(seq, "Failed to load source_in sequence")

    local sources = mixer.resolve_audio_sources(seq, 50, 24, 1, mock_media_cache)
    assert(#sources == 1, string.format("Expected 1 source, got %d", #sources))
    local src = sources[1]

    -- duration_us should be (source_out - source_in) / clip_rate * 1e6
    -- = (240000 - 48000) / 48000 * 1e6 = 192000/48000 * 1e6 = 4000000 us (4 seconds)
    local expected_duration = math.floor(
        (240000 - 48000) * 1000000 * 1 / 48000)  -- = 4000000
    assert(src.duration_us == expected_duration,
        string.format("Duration should be %d (4s), got %d (would be %d with bug)",
            expected_duration, src.duration_us,
            math.floor(240000 * 1000000 / 48000)))

    -- Bug check: if duration was computed as source_out/rate, it would be 5s
    local bug_duration = math.floor(240000 * 1000000 / 48000)  -- 5000000
    assert(src.duration_us ~= bug_duration,
        "REGRESSION: duration_us computed from source_out alone (over-fetch bug)")

    print(string.format("  duration=%d us (correct: 4s, not 5s)", src.duration_us))

    -- Also verify clip_end_us is correct
    -- clip_end = (timeline_start + duration) * 1e6 / seq_fps
    -- = (24 + 96) * 1e6 / 24 = 5000000 us
    local expected_end = math.floor((24 + 96) * 1000000 / 24)
    assert(src.clip_end_us == expected_end,
        string.format("clip_end should be %d, got %d", expected_end, src.clip_end_us))

    print(string.format("  clip_end=%d us (correct)", src.clip_end_us))

    -- Verify source_offset_us accounts for source_in > 0
    -- seek_us = source_in * 1e6 * fps_den / fps_num = 48000 * 1e6 / 48000 = 1000000
    -- timeline_start_us = 24 * 1e6 / 24 = 1000000
    -- source_offset = timeline_start_us - seek_us = 1000000 - 1000000 = 0
    assert(src.source_offset_us == 0,
        string.format("source_offset should be 0, got %d", src.source_offset_us))

    print("  source_offset=0 (timeline_start matches seek position)")
    print("  source_in > 0 duration passed")
end

--------------------------------------------------------------------------------
-- Test 4: Audio-only media detection (fps >= 1000 means audio-only → skip conform)
--------------------------------------------------------------------------------
print("\n--- audio-only media: no conform for high sample rate ---")
do
    -- The audio clip in srcin_seq uses 48000/1 rate (audio-only)
    -- At frame 50: Mixer should NOT apply conform even though 48000 != 24
    -- Because media_fps = 48000 >= 1000 → not video → skip conform

    local seq = Sequence.load("srcin_seq")
    local sources = mixer.resolve_audio_sources(seq, 50, 24, 1, mock_media_cache)
    assert(#sources == 1)

    -- If conform was wrongly applied, source_offset would be different from 0
    -- (because "48000fps" vs "24fps" would be a huge mismatch)
    assert(sources[1].source_offset_us == 0,
        string.format("Audio-only: source_offset should be 0 (no conform), got %d",
            sources[1].source_offset_us))

    print("  audio-only media correctly skips conform")
end

print("\n✅ test_mixer_extended.lua passed")
