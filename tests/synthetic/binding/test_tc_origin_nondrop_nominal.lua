-- test_tc_origin_nondrop_nominal.lua — non-drop timecode counts NOMINAL frames.
--
-- Domain: a non-drop SMPTE timecode label "HH:MM:SS:FF" enumerates frames at the
-- NOMINAL integer rate, not the true fractional rate. For 23.976 fps (24000/1001)
-- the nominal rate is 24, so the label 01:00:00:00 is frame number
--   (1*3600 + 0*60 + 0) * 24 + 0 = 86400.
-- Converting the label with the FRACTIONAL rate (3600 * 23.976 = 86313) is wrong
-- by ~87 frames/hour and corrupts every TC-origin-dependent calculation (master
-- media-ref placement, SendToResolve MediaStartTime, relink TC sync).
--
-- The fixture carries an embedded `timecode=01:00:00:00` tag at 24000/1001; this
-- exercises the real EMP extraction path (Media:get_start_tc → EMP first_frame_tc).
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/binding/test_tc_origin_nondrop_nominal.lua
local test_env = require("test_env")
local database = require("core.database")
local Media    = require("models.media")

print("=== test_tc_origin_nondrop_nominal.lua ===")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")

local db_path = "/tmp/jve/test_tc_origin_nondrop_nominal.db"
os.execute("mkdir -p /tmp/jve")
os.remove(db_path)
assert(database.init(db_path))
local db = assert(database.get_connection(), "no db connection")
db:exec("INSERT INTO projects (id, name, fps_mismatch_policy, settings, "
    .. "created_at, modified_at) VALUES ('p', 'TC', 'resample', "
    .. "'{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)")

-- No TC metadata on the row → get_start_tc must extract it from the file via EMP.
local m = Media.create({
    id = "m_tc01", project_id = "p", name = "A005_C052_0925BL_001_tc01.mp4",
    file_path = FIXTURE,
    duration_frames = 100, fps_numerator = 24000, fps_denominator = 1001,
    width = 1920, height = 1080,
})
assert(m:save(db), "media save failed")

local EXPECTED = 86400  -- 01:00:00:00 @ non-drop 23.976 → 3600 * 24 nominal frames
local tc, rate = m:get_start_tc()
assert(tc == EXPECTED, string.format(
    "non-drop TC 01:00:00:00 @23.976 must extract %d nominal frames, got %s. "
    .. "(86313 = the bug: 3600 * fractional 23.976 instead of 3600 * 24 nominal.)",
    EXPECTED, tostring(tc)))
print(string.format("  ✓ TC origin = %d frames @ rate %s", tc, tostring(rate)))
print("✅ test_tc_origin_nondrop_nominal.lua passed")
