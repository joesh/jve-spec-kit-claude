-- Domain behavior: a still image is relinkable.
--
-- A still (TIFF/PNG/JPEG/…) has no temporal extent — it is a single frame the
-- editor holds for whatever duration the timeline clip asks for. The model
-- already encodes this: a still is a one-frame media (Media.classify_is_still
-- keys on duration_frames == 1). So when relinking finds the still's file, the
-- coverage question "does the candidate contain the clip's source range?" must
-- answer YES for the still's whole [0,1) source — a still always covers itself.
--
-- The bug this guards: the relink probe reported NO duration for a still
-- (the decoder exposes a video stream with no temporal duration), so the
-- containment check bailed and every still was dropped as "duration
-- unreadable" — permanently unrelinkable, even sitting right next to its file.

local env      = require("synthetic.integration.integration_test_env")
local EMP      = env.require_emp()
local relinker = require("core.media_relinker")

print("--- test_relink_still_image ---")

local STILL = env.test_media_path("stills/test_still.png")

-- Sanity: the decoder genuinely reports a still as a video stream with no
-- temporal duration (the condition that used to defeat the relinker). If this
-- ever changes, the test below is no longer exercising the real case.
local info = EMP.MEDIA_PROBE(STILL)
assert(info and info.has_video, "fixture must probe as a video stream")
assert(not (info.has_duration and info.duration_us and info.duration_us > 0),
    "fixture must be a still (no temporal duration) for this test to be meaningful")

-- The relinker's interpretation of the file: a still resolves to a coverable
-- one-frame media (the model's representation), not a durationless blank.
local probe = relinker.probe_file_emp(STILL)
assert(probe, "relinker probe of a still must succeed")
assert(probe.duration_frames == 1, string.format(
    "a still must be interpreted as a single-frame media, got duration_frames=%s",
    tostring(probe.duration_frames)))

-- Coverage: the still's full source range [0,1) is contained in the candidate.
-- (stored_rate is the still's frame rate; a still always covers itself.)
local stored_rate = (info.fps_num and info.fps_den and info.fps_den > 0)
    and (info.fps_num / info.fps_den) or 25
assert(relinker.check_extent_containment(0, 1, probe, stored_rate),
    "a still's own [0,1) source range must be contained in the still file")

print("✅ test_relink_still_image.lua passed")
