-- Domain behavior under test:
--   Once peaks exist for a media file, asking the peak cache whether peaks
--   are available for that file must answer "yes" and NOT trigger a new
--   generation — regardless of whether the filesystem reports the file's
--   modification time with whole-second or sub-second precision.
--
-- Why a regression test exists here:
--   Pro Tools / Resolve / the editor itself write files fast enough that
--   their mtime routinely carries a non-zero nanosecond fraction. If the
--   cache's "is this peak file still current?" decision compares an
--   integer-seconds value (from the peak file's own recorded stamp)
--   against a float-seconds value (from a fresh stat call) with `==`,
--   every currently-valid peak file appears stale on project reopen and
--   re-generation cascades — for a project with hundreds of audio files
--   this blocks waveform display for the duration of a full rescan.

local env = require("integration.integration_test_env")
local EMP = env.require_emp()

print("--- test_peak_cache_mtime_fractional ---")

-- -----------------------------------------------------------------------
-- Arrange: a media file whose on-disk mtime carries a sub-second fraction.
-- -----------------------------------------------------------------------
local FIXTURE = env.test_media_path("test_tone_48k_stereo.wav")
local SCRATCH = "/tmp/jve/peak_mtime_fractional.wav"
os.execute(string.format("mkdir -p /tmp/jve && cp %q %q && touch %q",
    FIXTURE, SCRATCH, SCRATCH))

local fs_utils = require("core.fs_utils")
local reported_mtime = assert(fs_utils.file_mtime(SCRATCH),
    "filesystem did not report an mtime for the scratch file")
assert(reported_mtime > math.floor(reported_mtime),
    "test precondition: filesystem must report a sub-second fraction on this file")

-- -----------------------------------------------------------------------
-- Act: generate peaks once, then open the resulting file and ask whether
-- it still identifies the media it was generated from.
-- -----------------------------------------------------------------------
local media_id = "test_peak_cache_mtime_fractional"
local peak_path = "/tmp/jve/peak_mtime_fractional.peaks"
os.remove(peak_path)
EMP.PEAK_CANCEL(media_id)
EMP.PEAK_REQUEST(media_id, SCRATCH, peak_path)

local deadline = os.time() + 30
local final_status
while os.time() < deadline do
    final_status = EMP.PEAK_STATUS(media_id)
    if final_status and (final_status.state == "complete"
            or final_status.state == "failed") then break end
    os.execute("sleep 0.05")
end
assert(final_status and final_status.state == "complete",
    "peak generation did not complete within deadline")

local handle = assert(EMP.PEAK_LOAD(peak_path),
    "PEAK_LOAD returned nil for the file we just generated")
local header = assert(EMP.PEAK_HEADER(handle),
    "PEAK_HEADER returned nil for a loaded peak handle")
EMP.PEAK_RELEASE(handle)

-- -----------------------------------------------------------------------
-- Assert: the peak file identifies the same media the generator was asked
-- to read. We express "same media" the way any filesystem tool would —
-- agreement at whole-second resolution, independent of however much
-- fractional precision the filesystem chose to carry.
-- -----------------------------------------------------------------------
local header_seconds = header.source_mtime
local file_seconds = math.floor(reported_mtime)
assert(header_seconds == file_seconds, string.format(
    "peak file's recorded source timestamp (%d) should match the fixture's\n"
    .. "current whole-second mtime (%d, from reported %s). A mismatch here\n"
    .. "means the cache will treat every fresh peak file as stale and\n"
    .. "regenerate.",
    header_seconds, file_seconds, tostring(reported_mtime)))

os.remove(peak_path)
os.remove(SCRATCH)

print("✅ test_peak_cache_mtime_fractional passed")
