-- Domain behavior under test:
--   A peak file whose audio sample coverage falls substantially short of
--   the media file it claims to describe must not be trusted by the peak
--   cache. On next project-open, the cache must reject it, delete it, and
--   trigger regeneration — regardless of whether its recorded mtime still
--   matches the media's mtime.
--
-- Why a regression test exists here:
--   Peak generation has been observed to silently accept a mid-stream
--   zero-frame read as clean EOF, writing a peak file that covers only
--   ~50% of the real audio. The root cause is not understood (TSO
--   2026-04-24, anamnesis-gold-timeline). Once such a file is on disk,
--   its mtime matches the media's mtime, so the mtime-only check served
--   it as authoritative across every subsequent project-open — wrong
--   waveform coverage became sticky. The coverage cross-check breaks the
--   stickiness: any file short of PEAK_COVERAGE_MIN_FRACTION (95%) of
--   the media's true sample count gets dropped and regenerated.

local env = require("integration.integration_test_env")
local EMP = env.require_emp()

print("--- test_peak_cache_coverage_regen ---")

-- -----------------------------------------------------------------------
-- Arrange: generate complete peaks for a real audio fixture, then surgery
-- the on-disk peak file so its level-0 bin count claims only half the
-- real coverage. Preserve the header mtime so the mtime-only check still
-- passes — this isolates the coverage-check path.
-- -----------------------------------------------------------------------
local FIXTURE = env.test_media_path("test_tone_48k_stereo.wav")
local SCRATCH = "/tmp/jve/peak_coverage_regen.wav"
os.execute(string.format("mkdir -p /tmp/jve && cp %q %q", FIXTURE, SCRATCH))

local fs_utils = require("core.fs_utils")
local reported_mtime = assert(fs_utils.file_mtime(SCRATCH),
    "filesystem did not report an mtime for the scratch file")

local media_id = "test_peak_cache_coverage_regen"
local peak_path = "/tmp/jve/peak_coverage_regen.peaks"

local function wait_for_complete(mid, deadline_s)
    local deadline = os.time() + deadline_s
    while os.time() < deadline do
        local s = EMP.PEAK_STATUS(mid)
        if s and s.state == "complete" then return true end
        os.execute("sleep 0.05")
    end
    return false
end

os.remove(peak_path)
EMP.PEAK_CANCEL(media_id)
EMP.PEAK_REQUEST(media_id, SCRATCH, peak_path)
assert(wait_for_complete(media_id, 30),
    "initial peak generation did not complete within 30s")

-- Read back the header so we know the true bins_per_level[0] — this is
-- what a complete peak file should report.
local true_handle = assert(EMP.PEAK_LOAD(peak_path))
local true_hdr = assert(EMP.PEAK_HEADER(true_handle))
EMP.PEAK_RELEASE(true_handle)
assert(true_hdr.bins_per_level and true_hdr.bins_per_level[1],
    "header did not expose bins_per_level[1]")
local true_bins = true_hdr.bins_per_level[1]
assert(true_bins > 100, string.format(
    "fixture too short for this test (bins=%d); pick a longer fixture", true_bins))

-- Halve bins_per_level[0] in the on-disk header. The struct layout is
-- 4-byte magic, 4-byte version, 8-byte mtime, 4-byte rate, 2-byte ch,
-- 4-byte spp, 2-byte levels, then bins_per_level[4] (each uint64_t LE).
-- level 0 lives at offset 28..35 (8 bytes).
local halved_bins = math.floor(true_bins / 2)
local function write_le_u64(path, offset, value)
    local f = assert(io.open(path, "r+b"), "open for header edit failed")
    f:seek("set", offset)
    local bytes = {}
    for i = 0, 7 do
        bytes[i + 1] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    f:write(table.concat(bytes))
    f:close()
end
write_le_u64(peak_path, 28, halved_bins)

-- Sanity-check the on-disk surgery: reload and confirm the header now
-- reports the halved count.
local trunc_handle = assert(EMP.PEAK_LOAD(peak_path))
local trunc_hdr = assert(EMP.PEAK_HEADER(trunc_handle))
assert(trunc_hdr.bins_per_level[1] == halved_bins, string.format(
    "header surgery failed: expected halved=%d, got %d",
    halved_bins, trunc_hdr.bins_per_level[1]))
EMP.PEAK_RELEASE(trunc_handle)

-- The surgery writes at offset 28 and must not have disturbed the
-- source_mtime field at offset 8 — we need the mtime check to still
-- pass so the rejection we're testing is attributable to coverage.
local post_surgery_handle = assert(EMP.PEAK_LOAD(peak_path))
local post_surgery_hdr = assert(EMP.PEAK_HEADER(post_surgery_handle))
EMP.PEAK_RELEASE(post_surgery_handle)
assert(post_surgery_hdr.source_mtime == math.floor(reported_mtime),
    "surgery must not disturb the header's source_mtime field")

-- -----------------------------------------------------------------------
-- Act: hand the surgically-truncated peak file to peak_cache and verify
-- rejection. peak_cache.init_for_project is the supported way to set up
-- cache_dir; we give it an empty project so it does nothing else.
-- -----------------------------------------------------------------------
local peak_cache = require("core.media.peak_cache")
local database = require("core.database")
local db_path = "/tmp/jve/test_peak_coverage_regen_" .. os.time() .. ".jvp"
os.remove(db_path); os.remove(db_path.."-wal"); os.remove(db_path.."-shm")
assert(database.init(db_path), "database.init failed")
local db = database.get_connection()
db:exec(require("import_schema"))
local project_id = "proj-peak-coverage"
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) VALUES ('%s', 'p', %d, %d, 'passthrough')",
    project_id, now, now))
peak_cache.init_for_project(project_id)

local cache_peak_path = database.get_peak_cache_dir(project_id) .. "/" .. media_id .. ".peaks"
os.execute(string.format("mv %q %q", peak_path, cache_peak_path))

local expected_samples = true_bins * true_hdr.base_spp

-- Half-coverage file must be rejected.
local loaded_truncated = peak_cache._try_load_existing_for_test(
    media_id, SCRATCH, reported_mtime, expected_samples)
assert(loaded_truncated == false,
    "a peak file covering half the media's samples must not be loaded "
    .. "as authoritative — it must be rejected and deleted")

-- Rejection side effects: the file must be gone so the next open
-- triggers regeneration.
local f = io.open(cache_peak_path, "rb")
assert(f == nil, "rejected peak file must be deleted from disk, not left in place")

-- Control: a file whose coverage IS sufficient must load successfully.
-- Use a fresh media_id to avoid PEAK_REQUEST deduping against the
-- prior completed job's status.
local control_media_id = media_id .. "_control"
local control_peak_path = database.get_peak_cache_dir(project_id)
    .. "/" .. control_media_id .. ".peaks"
os.remove(control_peak_path)
EMP.PEAK_CANCEL(control_media_id)
EMP.PEAK_REQUEST(control_media_id, SCRATCH, control_peak_path)
assert(wait_for_complete(control_media_id, 30),
    "control peak generation did not complete within 30s")

local loaded_complete = peak_cache._try_load_existing_for_test(
    control_media_id, SCRATCH, reported_mtime, expected_samples)
assert(loaded_complete == true,
    "a peak file with full coverage and matching mtime must be loaded")
os.remove(control_peak_path)

-- Cleanup
database.shutdown()
os.remove(db_path); os.remove(db_path.."-wal"); os.remove(db_path.."-shm")
os.remove(cache_peak_path)
os.remove(SCRATCH)

print("✅ test_peak_cache_coverage_regen passed")
