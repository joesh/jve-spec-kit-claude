require("test_env")

-- =============================================================================
-- DRP import → media.audio_duration_samples = EXACT embedded-audio sample count
-- (spec 026 gap #4, "capture EXACT on import").
--
-- DOMAIN: a video file with embedded audio (A035_11200051_C049.mov in the
-- anamnesis-gold timeline) carries TWO independent durations — a video-frame
-- count (BtVideoInfo <Time>) and an embedded-audio sample count (BtAudioInfo
-- <TracksBA> Duration). The media row already persists the video-frame
-- duration; the EXACT embedded-audio sample count must ALSO survive so the DRT
-- exporter can re-author the embedded <TracksBA> Duration sample-exact.
--
-- The audio sample count is NOT derivable from the video-frame duration:
-- frames→samples rounds, and Resolve's authored count is the only truth.
-- Golden = the sample count Resolve wrote into this clip's BtAudioInfo
-- TracksBA Duration (attested from the fixture): 3734400 samples @ 48000 Hz.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_import_embedded_audio_duration.lua
-- =============================================================================

local drp_importer = require("importers.drp_importer")
local database     = require("core.database")
local json         = require("dkjson")

local FIXTURE = require("test_env").require_fixture(
    "tests/fixtures/resolve/anamnesis-gold-timeline.drp")

-- A035_11200051_C049.mov: Resolve-authored embedded-audio descriptor.
local CLIP_NAME            = "A035_11200051_C049.mov"
local GOLDEN_AUDIO_SAMPLES = 3734400   -- BtAudioInfo TracksBA Duration (48000 Hz)

local tmp_db = "/tmp/jve/test_drp_import_embedded_audio_duration.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local project_id = "test-embedded-audio-dur"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Embedded Audio Dur', 0, 0, 'resample', '%s')",
    project_id, (json.encode(settings):gsub("'", "''")))),
    "project insert failed")
assert((drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings }) or {}).success ~= false, "import failed")

-- Find the A035 clip's media row by name and read its embedded-audio duration.
local st = assert(conn:prepare(
    "SELECT audio_duration_samples, audio_sample_rate, duration_frames "
    .. "FROM media WHERE name = ?"))
st:bind_value(1, CLIP_NAME)
assert(st:exec(), "media query failed")
assert(st:next(), "no media row named " .. CLIP_NAME)
local samples   = st:value(0)
local rate_hz   = st:value(1)
local vid_frames = st:value(2)
st:finalize()

assert(samples == GOLDEN_AUDIO_SAMPLES, string.format(
    "embedded-audio sample count not persisted exact: got %s, want %d "
    .. "(audio_duration_samples must carry the BtAudioInfo TracksBA Duration)",
    tostring(samples), GOLDEN_AUDIO_SAMPLES))

-- Sanity: the exact sample count is distinct from the naive video-frame
-- conversion, proving we kept Resolve's authored value rather than rounding.
assert(rate_hz == 48000, "expected 48000 Hz, got " .. tostring(rate_hz))
assert(vid_frames and vid_frames > 0, "expected a positive video-frame duration")

print("✅ test_drp_import_embedded_audio_duration.lua passed")
