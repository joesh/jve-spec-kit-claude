--- Black-box test: still-image classification for browser icons.
-- Covers three domain behaviors:
--   1. Image file formats (PNG, JPEG, TIFF, …) are classified as stills.
--      Motion formats (H264, ProRes, DNxHD) of real-world durations are not.
--      A single-frame video export is classified as a still regardless of container.
--   2. The still-image flag survives save-and-reload through SQLite with fidelity.
--   3. Invalid classifier inputs (non-numeric width / duration) fail fast, not silently.
require("test_env")

local database = require("core.database")
local Project = require("models.project")
local Media = require("models.media")

local failed = 0
local function check(label, cond)
    if cond then
        print("  PASS: " .. label)
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

-- ---------------------------------------------------------------------------
-- Part 1: classifier domain behavior (pure function, no DB)
-- ---------------------------------------------------------------------------
-- Expected answers derived from domain knowledge (image file formats are
-- stills; motion codecs with non-trivial duration are not). NOT from tracing
-- the classifier implementation.

-- Image file formats → still
check("PNG is a still", Media.classify_is_still("png", 1920, 1) == true)
check("JPEG is a still", Media.classify_is_still("jpeg", 3840, 1) == true)
check("MJPEG (image codec family) is a still",
    Media.classify_is_still("mjpeg", 1920, 1) == true)
check("TIFF is a still", Media.classify_is_still("tiff", 2048, 1) == true)
check("HEIC is a still", Media.classify_is_still("heic", 4032, 1) == true)

-- Case-insensitive codec name
check("PNG recognized regardless of case",
    Media.classify_is_still("PNG", 1920, 1) == true)

-- Long-form motion video → NOT still (non-trivial duration, motion codec)
check("H264 90min @ 24fps is not a still",
    Media.classify_is_still("h264", 1920, 129600) == false)
check("ProRes 10min clip is not a still",
    Media.classify_is_still("prores", 1920, 14400) == false)
check("DNxHD clip is not a still",
    Media.classify_is_still("dnxhd", 1920, 24000) == false)

-- Audio-only (no video dimensions) is NOT a still, regardless of duration
check("Audio-only PCM (zero width) is not a still",
    Media.classify_is_still("pcm_s16le", 0, 48000 * 60) == false)
check("Audio-only AAC is not a still",
    Media.classify_is_still("aac", 0, 48000 * 120) == false)

-- Single-frame video export → still (poster-frame export case)
check("Single-frame H264 export is a still",
    Media.classify_is_still("h264", 1920, 1) == true)

-- Unknown codec with multi-frame duration → not a still
check("Unknown codec with many frames is not a still",
    Media.classify_is_still("", 1920, 500) == false)
check("Nil codec with many frames is not a still",
    Media.classify_is_still(nil, 1920, 500) == false)

-- ---------------------------------------------------------------------------
-- Width nil = "no video stream" (audio-only, compound-clip). Domain behavior:
-- nil width with an image codec is still a still; nil width with a motion
-- codec or no codec is not a still.
-- ---------------------------------------------------------------------------
check("PNG with unknown width is a still (codec alone decides)",
    Media.classify_is_still("png", nil, 1) == true)
check("motion codec with unknown width is not a still",
    Media.classify_is_still("h264", nil, 5000) == false)
check("no codec and no width is not a still",
    Media.classify_is_still(nil, nil, 5000) == false)

-- ---------------------------------------------------------------------------
-- Failure paths: non-numeric / invalid duration must fail-fast, not degrade
-- ---------------------------------------------------------------------------
local ok_d_nil = pcall(Media.classify_is_still, "h264", 1920, nil)
check("nil duration is a hard error (schema says duration > 0)", not ok_d_nil)

local ok_d_zero = pcall(Media.classify_is_still, "h264", 1920, 0)
check("zero duration is a hard error", not ok_d_zero)

local ok_d_str = pcall(Media.classify_is_still, "h264", 1920, "100")
check("string duration is a hard error", not ok_d_str)

local ok_w_str = pcall(Media.classify_is_still, "h264", "1920", 100)
check("string width is a hard error", not ok_w_str)

-- ---------------------------------------------------------------------------
-- Part 2: still flag survives save-and-reload
-- ---------------------------------------------------------------------------
local db_path = "/tmp/jve/test_media_is_still_" .. os.time() .. ".jvp"
os.execute("mkdir -p /tmp/jve")
database.init(db_path)

local project = Project.create("IsStill Project", { fps_mismatch_policy = 'resample' })
assert(project:save())

local still_media = Media.create({
    id = "media_still_1",
    project_id = project.id,
    file_path = "/tmp/jve/test_still_image.png",
    name = "poster.png",
    duration_frames = 1,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 3840,
    height = 2160,
    codec = "png",
    is_still = true,
})
assert(still_media:save(), "save still media")

local motion_media = Media.create({
    id = "media_motion_1",
    project_id = project.id,
    file_path = "/tmp/jve/test_motion.mov",
    name = "sequence.mov",
    duration_frames = 144000,  -- 100 min @ 24fps
    fps_numerator = 24000,
    fps_denominator = 1001,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    codec = "h264",
    is_still = false,
})
assert(motion_media:save(), "save motion media")

local reloaded_still = Media.load("media_still_1")
assert(reloaded_still, "reloaded_still not nil")
check("still PNG survives save+reload as still",
    reloaded_still.is_still == true)

local reloaded_motion = Media.load("media_motion_1")
assert(reloaded_motion, "reloaded_motion not nil")
check("motion H264 survives save+reload as non-still",
    reloaded_motion.is_still == false)

-- Still flag defaults to false when unspecified on creation
local default_media = Media.create({
    id = "media_default_1",
    project_id = project.id,
    file_path = "/tmp/jve/test_default.mov",
    name = "default.mov",
    duration_frames = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    codec = "prores",
})
assert(default_media:save(), "save default media")
local reloaded_default = Media.load("media_default_1")
check("media created without a still flag reloads as non-still",
    reloaded_default and reloaded_default.is_still == false)

-- In-memory representation is boolean (not int) so callers can use strict equality
check("Media.create exposes still flag as boolean true",
    still_media.is_still == true)
check("Media.create exposes unset still flag as boolean false",
    default_media.is_still == false)

-- Non-boolean still flag at save time is a hard error (no silent coercion)
local bad_media = Media.create({
    id = "media_bad_still",
    project_id = project.id,
    file_path = "/tmp/jve/test_bad_still.mov",
    name = "bad.mov",
    duration_frames = 100,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    codec = "h264",
})
bad_media.is_still = "maybe"  -- caller corruption: non-boolean assignment
local ok_bad = pcall(function() bad_media:save() end)
check("non-boolean still flag on save is a hard error", not ok_bad)

os.remove(db_path)

if failed > 0 then
    print(string.format("\n%d check(s) failed", failed))
    os.exit(1)
end
print("\n✅ test_media_is_still.lua passed")
