#!/usr/bin/env luajit

-- Integration test: relink from original (untrimmed) media to trimmed media.
--
-- Domain behavior:
-- 1. Clips linked to original file play content at specific timecodes
-- 2. After relinking to a trimmed version of the same file, clips play the
--    SAME content — source_in/source_out don't change because TC is absolute
-- 3. Undo restores the original media link
-- 4. The relink command appears in the undo history as a top-level entry
--
-- Fixture files:
--   untrimmed: A007_05202055_C007.mov — TC 20:55:01:23, 1602 frames (64s)
--   trimmed:   same filename in media-managed path — TC 20:55:13:17, 562 frames (22.5s)

local test_env = require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local Media = require("models.media")
local Sequence = require("models.sequence")
local Command = require("command")

print("=== test_relink_trimmed_media.lua ===")

local ORIGINAL = test_env.require_fixture(
    "tests/fixtures/media/anamnesis/untrimmed/Day2/A007/A007_05202055_C007.mov")
local TRIMMED = test_env.require_fixture(
    "tests/fixtures/media/anamnesis/2026-02-28-anamnesis joe edit-mm/Volumes/AnamBack4 Joe/Footage/Day 2/A007/A007_05202055_C007.mov")

-- TC values at 25fps (from ffprobe).
-- Original: starts at 20:55:01:23 = 1886298 frames, 1602 frames long (64s)
-- Trimmed:  starts at 20:55:13:17 = 1886592 frames, 562 frames long (22.5s)
-- The trimmed file is a subset of the original starting 294 frames later.
local FPS = 25
local TRIMMED_TC = 20*3600*FPS + 55*60*FPS + 13*FPS + 17  -- 1886592 frames

-- =========================================================================
-- Setup: create a test project with a clip linked to the ORIGINAL file
-- =========================================================================

local TEST_DB = "/tmp/jve/test_relink_trimmed.db"
os.execute("mkdir -p /tmp/jve")
os.remove(TEST_DB); os.remove(TEST_DB.."-wal"); os.remove(TEST_DB.."-shm")

assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require("import_schema"))

-- Create project + sequence
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at) VALUES ('proj1', 'Test', %d, %d)", now, now))
local seq = Sequence.create("Timeline", "proj1", {fps_numerator = FPS, fps_denominator = 1}, 1920, 1080,
    { kind = "nested", audio_rate = 48000, id = "seq1" })
assert(seq:save())

-- Create track
db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1)"))

-- Create media pointing to ORIGINAL file
local media = Media.create({
    id = "media_orig",
    project_id = "proj1",
    file_path = ORIGINAL,
    name = "A007_05202055_C007.mov",
    duration_frames = 1602,
    fps_numerator = FPS, fps_denominator = 1,
    width = 1920, height = 1080,
})
assert(media:save())

-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_orig")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media_orig", "proj1")

-- Create a clip that uses content within the trimmed file's TC range.
-- Trimmed covers [TRIMMED_TC, TRIMMED_TC + 562). Put clip at TRIMMED_TC + 100
-- so the content exists in BOTH the original and the trimmed version.
local CLIP_SOURCE_IN = TRIMMED_TC + 100   -- absolute TC: 1886692
local CLIP_SOURCE_OUT = TRIMMED_TC + 200  -- 100 frames of content
local clip = Clip.create({
        name = "Test Clip",
        id = "clip1",
        project_id = "proj1",
        track_id = "track_v1",
        nested_sequence_id = MC_TEST,
        owner_sequence_id = "seq1",
        timeline_start_frame = 0,
        duration_frames = 100,
        source_in_frame = CLIP_SOURCE_IN,
        source_out_frame = CLIP_SOURCE_OUT,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
        enabled = 1,
    })
assert(clip:save({skip_occlusion = true}))

command_manager.init("seq1", "proj1")

-- =========================================================================
-- Test 1: Relink to trimmed file — source_in/source_out unchanged
-- =========================================================================

print("\n--- Test 1: relink to trimmed file ---")
do
    local clip_before = Clip.load("clip1")
    assert(clip_before.source_in == CLIP_SOURCE_IN, "setup: source_in wrong")
    local media_before = Media.load("media_orig")
    assert(media_before.file_path == ORIGINAL, "setup: media path wrong")

    -- Execute RelinkClips — change media path from original to trimmed
    local cmd = Command.create("RelinkClips", "proj1")
    cmd:set_parameter("clip_relink_map", {
        clip1 = {
            new_source_in = CLIP_SOURCE_IN,   -- unchanged (TC is absolute)
            new_source_out = CLIP_SOURCE_OUT,  -- unchanged
        },
    })
    cmd:set_parameter("media_path_changes", {
        media_orig = TRIMMED,
    })
    cmd:set_parameter("project_id", "proj1")

    local result = command_manager.execute(cmd)
    assert(result.success, "RelinkClips failed: " .. tostring(result.error_message))

    -- Verify source_in/source_out didn't change
    local clip_after = Clip.load("clip1")
    assert(clip_after.source_in == CLIP_SOURCE_IN,
        string.format("source_in must not change: expected %d, got %d",
            CLIP_SOURCE_IN, clip_after.source_in))
    assert(clip_after.source_out == CLIP_SOURCE_OUT,
        string.format("source_out must not change: expected %d, got %d",
            CLIP_SOURCE_OUT, clip_after.source_out))

    -- Verify media path changed
    local media_after = Media.load("media_orig")
    assert(media_after.file_path == TRIMMED,
        "media path should point to trimmed file")

    -- The content at source_in=CLIP_SOURCE_IN exists in the trimmed file
    -- (clip's TC range is within [TRIMMED_TC, TRIMMED_TC + 562)).
    -- The decoder computes file_pos = source_in - first_sample_tc:
    --   original: 1886692 - 1886298 = 394 frames into original
    --   trimmed:  1886692 - 1886592 = 100 frames into trimmed
    -- Same content at both locations.
    print("  ✓ relink preserved absolute TC source coordinates")
end

-- =========================================================================
-- Test 2: Undo restores original media path
-- =========================================================================

print("\n--- Test 2: undo restores original ---")
do
    local undo_result = command_manager.undo()
    assert(undo_result.success, "Undo failed: " .. tostring(undo_result.error_message))

    local clip_restored = Clip.load("clip1")
    assert(clip_restored.source_in == CLIP_SOURCE_IN, "Undo: source_in not restored")
    assert(clip_restored.source_out == CLIP_SOURCE_OUT, "Undo: source_out not restored")

    local media_restored = Media.load("media_orig")
    assert(media_restored.file_path == ORIGINAL,
        string.format("Undo: media path should be original, got %s",
            media_restored.file_path:match("[^/]+$") or media_restored.file_path))

    print("  ✓ undo restored original media path and source coordinates")
end

-- =========================================================================
-- Test 3: Redo re-applies the relink
-- =========================================================================

print("\n--- Test 3: redo re-applies relink ---")
do
    local redo_result = command_manager.redo()
    assert(redo_result.success, "Redo failed: " .. tostring(redo_result.error_message))

    local media_redo = Media.load("media_orig")
    assert(media_redo.file_path == TRIMMED,
        "Redo: media path should be trimmed")

    local clip_redo = Clip.load("clip1")
    assert(clip_redo.source_in == CLIP_SOURCE_IN, "Redo: source_in not preserved")

    print("  ✓ redo re-applied relink correctly")
end

-- Final undo to clean up
command_manager.undo()

-- =========================================================================
-- Cleanup
-- =========================================================================

database.shutdown()
os.remove(TEST_DB); os.remove(TEST_DB.."-wal"); os.remove(TEST_DB.."-shm")

print("\n✅ test_relink_trimmed_media.lua passed")
