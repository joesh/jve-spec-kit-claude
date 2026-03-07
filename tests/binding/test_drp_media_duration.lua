#!/usr/bin/env luajit
-- TDD regression test: DRP importer media duration must reflect max source extent
-- across ALL clips referencing the same file, not just the first clip's timeline
-- edit duration.
--
-- Bug: media_lookup[file_path].duration was set to clip.duration (timeline edit
-- frames) of the first clip encountered, and the `not media_lookup[file_path]`
-- guard prevented later clips from updating it. This caused:
--   Sequence:set_playhead() assert failure: frame 1203 >= content_duration 99
-- because master clip content_duration was 99 (first edit length) instead of
-- the actual source extent (thousands of frames).
--
-- Fix: track max(source_extent_frames) across all clips referencing each file.
-- source_extent = source_in + source_duration (in video frames, regardless of
-- track type).

local test_env = require("test_env")

print("=== test_drp_media_duration.lua ===")

local drp_importer = require("importers.drp_importer")

-- Helper: construct a mock XML element
local function elem(tag, text, children)
    return {
        tag = tag,
        attrs = {},
        children = children or {},
        text = text or "",
    }
end

-- Helper: wrap clips in Items > Element structure matching real DRP XML
local function wrap_clips(...)
    local elements = {}
    for _, clip in ipairs({...}) do
        table.insert(elements, elem("Element", "", {clip}))
    end
    return elem("Items", "", elements)
end

--------------------------------------------------------------------------------
-- Test 1: Multiple clips from same file — duration = max(source_extent)
-- First clip: source_in=0, duration=99 (timeline) → source_extent=99
-- Second clip: source_in=1100, duration=200 (timeline) → source_extent=1300
-- Expected media duration: 1300 (not 99!)
--------------------------------------------------------------------------------

print("\n--- Test 1: Multiple clips same file → max(source_extent) ---")

local seq_multi = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),  -- VIDEO
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "first_edit"),
                elem("Start", "86400"),
                elem("Duration", "99"),           -- timeline edit = 99 frames
                elem("In", ""),                    -- source_in = 0
                elem("MediaFilePath", "/vol/media/interview.mov"),
            }),
            elem("Sm2TiVideoClip", "", {
                elem("Name", "second_edit"),
                elem("Start", "86499"),
                elem("Duration", "200"),           -- timeline edit = 200 frames
                elem("In", "1100"),                -- source_in = 1100 frames into file
                elem("MediaFilePath", "/vol/media/interview.mov"),
            })
        ),
    }),
})

local v_tracks, _, media_lookup = drp_importer._parse_resolve_tracks(seq_multi, 24)

assert(#v_tracks == 1, "Expected 1 video track")
assert(#v_tracks[1].clips == 2, "Expected 2 video clips")

local media = media_lookup["/vol/media/interview.mov"]
assert(media, "media_lookup should have entry for interview.mov")

-- Second clip reaches source_in=1100 + duration=200 = source_extent 1300
-- This must be the media duration, NOT the first clip's edit duration of 99
assert(media.duration == 1300, string.format(
    "Media duration should be 1300 (max source_extent), got %d", media.duration))
print("  ✓ Media duration = 1300 (max source_extent across clips)")

--------------------------------------------------------------------------------
-- Test 2: Single clip — duration = source_in + source_duration
-- Not timeline edit duration (which happens to match here, but the source is
-- what matters)
--------------------------------------------------------------------------------

print("\n--- Test 2: Single clip → source_in + source_duration ---")

local seq_single = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "solo_clip"),
                elem("Start", "0"),
                elem("Duration", "150"),
                elem("In", "500"),                 -- starts 500 frames in
                elem("MediaFilePath", "/vol/media/solo.mov"),
            })
        ),
    }),
})

local v2, _, ml2 = drp_importer._parse_resolve_tracks(seq_single, 24)

assert(#v2 == 1 and #v2[1].clips == 1)
local solo_media = ml2["/vol/media/solo.mov"]
assert(solo_media, "media_lookup should have entry for solo.mov")

-- source_in=500 + duration=150 = 650 (NOT 150 which is the timeline edit duration)
assert(solo_media.duration == 650, string.format(
    "Single clip media duration should be 650 (500+150), got %d", solo_media.duration))
print("  ✓ Single clip media duration = 650 (source_in + source_duration)")

--------------------------------------------------------------------------------
-- Test 3: Audio + video tracks sharing same file
-- Audio clip reaches deeper into source than video clip
-- Media duration should reflect the deepest reach in VIDEO FRAMES
--------------------------------------------------------------------------------

print("\n--- Test 3: Audio+video same file → deepest extent in frames ---")

local seq_av = elem("Sequence", "", {
    -- Video track: source_in=0, duration=100 → extent=100 frames
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "av_clip_v"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("In", ""),
                elem("MediaFilePath", "/vol/media/av_file.mov"),
            })
        ),
    }),
    -- Audio track: source_in=200 (timeline frames), duration=300 (timeline frames)
    -- Audio extent in frames = in_value + duration_raw = 200 + 300 = 500 frames
    elem("Sm2TiTrack", "", {
        elem("Type", "1"),  -- AUDIO
        wrap_clips(
            elem("Sm2TiAudioClip", "", {
                elem("Name", "av_clip_a"),
                elem("Start", "0"),
                elem("Duration", "300"),
                elem("In", "200"),
                elem("MediaFilePath", "/vol/media/av_file.mov"),
            })
        ),
    }),
})

local v3, a3, ml3 = drp_importer._parse_resolve_tracks(seq_av, 24)

assert(#v3 == 1, "Expected 1 video track")
assert(#a3 == 1, "Expected 1 audio track")

local av_media = ml3["/vol/media/av_file.mov"]
assert(av_media, "media_lookup should have entry for av_file.mov")

-- Audio extent in frames: in_value(200) + duration_raw(300) = 500
-- Video extent: 0 + 100 = 100
-- Max = 500
assert(av_media.duration == 500, string.format(
    "A/V media duration should be 500 (audio extends deeper), got %d", av_media.duration))
print("  ✓ A/V media duration = 500 (audio extent deeper than video)")

-- Audio channels should be set since we have an audio track
assert(av_media.audio_channels == 2, string.format(
    "audio_channels should be 2, got %s", tostring(av_media.audio_channels)))
print("  ✓ audio_channels = 2 (from audio track)")

--------------------------------------------------------------------------------
-- Test 4: First clip short, later clip long — regression guard
-- This is the exact bug scenario: first clip has edit duration 99,
-- but a later clip references frame 1203. MatchFrame would assert.
--------------------------------------------------------------------------------

print("\n--- Test 4: MatchFrame regression — deep offset clip ---")

local seq_match = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "intro"),
                elem("Start", "0"),
                elem("Duration", "99"),            -- short edit
                elem("In", ""),                    -- source_in=0
                elem("MediaFilePath", "/vol/media/long_interview.mov"),
            }),
            elem("Sm2TiVideoClip", "", {
                elem("Name", "highlight"),
                elem("Start", "99"),
                elem("Duration", "50"),
                elem("In", "1203"),                -- deep into source
                elem("MediaFilePath", "/vol/media/long_interview.mov"),
            })
        ),
    }),
})

local v4, _, ml4 = drp_importer._parse_resolve_tracks(seq_match, 24)

assert(#v4[1].clips == 2)
local match_media = ml4["/vol/media/long_interview.mov"]

-- highlight clip: source_in=1203 + duration=50 = 1253
-- This must be >= 1253 so set_playhead(1203) doesn't assert
assert(match_media.duration == 1253, string.format(
    "MatchFrame media duration must be >= 1253, got %d", match_media.duration))
print("  ✓ MatchFrame: media duration = 1253 (set_playhead(1203) safe)")

--------------------------------------------------------------------------------
-- Test 5: End-to-end — parse_drp_file applies blob duration from Time blob
-- A001_07232330_C004.mp4 has NumFrames=2890 in its BtVideoInfo/Time blob.
-- Without blob parsing, source_extent from timeline clips gives a smaller value
-- (e.g. 2774 from the deepest edit). Blob must override.
--------------------------------------------------------------------------------

print("\n--- Test 5: End-to-end DRP parse → blob duration override ---")

local fixture_path = test_env.resolve_repo_path("tests/fixtures/resolve/sample_project.drp")
local f = io.open(fixture_path)
assert(f, "fixture not found: " .. fixture_path)
f:close()

local result = drp_importer.parse_drp_file(fixture_path)
assert(result.success, "parse_drp_file failed: " .. tostring(result.error))

-- Find A001_07232330_C004.mp4 in media_items
local target_name = "A001_07232330_C004.mp4"
local target_media = nil
for _, item in ipairs(result.media_items) do
    if item.file_path and item.file_path:find(target_name, 1, true) then
        target_media = item
        break
    end
end
assert(target_media, "media_items should contain " .. target_name)

-- Blob-authoritative duration = 2890 (from Time blob NumFrames)
-- This is larger than any single timeline clip's source_extent
assert(target_media.duration == 2890, string.format(
    "Media duration for %s should be 2890 (from Time blob), got %s",
    target_name, tostring(target_media.duration)))
print("  ✓ " .. target_name .. " duration=2890 (Time blob authoritative)")

--------------------------------------------------------------------------------
-- Test 6: End-to-end — pool master clips have audio_duration from blob
-- APM_Adobe_Going Home_v3.wav has TracksBA Duration=3130909 samples at 48000Hz
-- Verify the blob was decoded and stored on the pool master clip data.
-- (The blob-decoded file_path may not match media_items paths exactly,
-- so we verify the blob data is present on the PMC rather than checking
-- media_items duration.)
--------------------------------------------------------------------------------

print("\n--- Test 6: Pool master clip audio blob decoded ---")

local audio_name_fragment = "Going Home"
local found_audio_pmc = false
for _, pmc in ipairs(result.pool_master_clips) do
    if pmc.name and pmc.name:find(audio_name_fragment, 1, true) and pmc.audio_duration then
        assert(pmc.audio_duration.samples > 0, "audio_duration.samples should be > 0")
        assert(pmc.audio_duration.sample_rate > 0, "audio_duration.sample_rate should be > 0")
        found_audio_pmc = true
        print("  ✓ PMC '" .. pmc.name .. "' has audio_duration: "
            .. pmc.audio_duration.samples .. " samples @ " .. pmc.audio_duration.sample_rate .. " Hz")
        break
    end
end
assert(found_audio_pmc, "Should find a pool master clip with audio_duration blob data")

print("\n✅ test_drp_media_duration.lua passed")
