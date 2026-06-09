-- Domain behavior under test:
--   When a media file's filesystem mtime has drifted from the value
--   stored in its cached peak file (cp, touch, fixture refresh, fs
--   migration) but the BYTES on disk are unchanged, the peak cache
--   must NOT regenerate peaks. Instead it must verify content via
--   a fingerprint and, on match, refresh the stored mtime in place
--   so future opens hit the fast path.
--
--   Symmetrically: if the bytes ARE different, the cache must reject
--   the stale peaks and regenerate — the rescue path is for spurious
--   mtime drift only.
--
-- Why a regression test exists here:
--   pre-2026-06-03 the cache compared filesystem mtime to the stored
--   mtime as the only freshness signal. On a real Resolve workflow
--   (TSO 2026-06-03) opening a project triggered regeneration of
--   562 peak files purely because the fixture media had been re-laid
--   out with fresh mtimes. The hybrid policy fixes the cost while
--   strengthening the correctness: bytes-identity, not inode-rewrite,
--   is the signal we actually want.

local env = require("integration.integration_test_env")
local EMP = env.require_emp()

print("--- test_peak_cache_hash_rescue ---")

-- -----------------------------------------------------------------------
-- Arrange: generate peaks against a real audio fixture, capture its
-- mtime, then perturb the file's mtime (NOT its bytes) and verify the
-- cache rescues the existing peaks.
-- -----------------------------------------------------------------------
local FIXTURE = env.test_media_path("test_tone_48k_stereo.wav")
local SCRATCH = "/tmp/jve/peak_hash_rescue.wav"
os.execute(string.format("mkdir -p /tmp/jve && cp %q %q", FIXTURE, SCRATCH))

local fs_utils = require("core.fs_utils")
local original_mtime = assert(fs_utils.file_mtime(SCRATCH),
    "filesystem did not report an mtime for the scratch file")

local media_id = "test_peak_cache_hash_rescue"
local peak_path = "/tmp/jve/peak_hash_rescue.peaks"

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

-- Confirm the header recorded source_size and a non-zero content_hash —
-- the v2 contract. Without these the rescue path can't fire.
local hdr_handle = assert(EMP.PEAK_LOAD(peak_path))
local hdr = assert(EMP.PEAK_HEADER(hdr_handle))
EMP.PEAK_RELEASE(hdr_handle)
assert(hdr.version == 2,
    "v2 peak format expected — bump did not take effect")
assert(hdr.source_size and hdr.source_size > 0,
    "header must record source_size at gen time")
assert(hdr.content_hash and #hdr.content_hash == 16,
    "header must record a 16-char content_hash")
local original_hash = hdr.content_hash
local original_size = hdr.source_size

-- Set up peak_cache against an empty project so init_for_project has
-- a real cache_dir to plant the file under.
local peak_cache = require("core.media.peak_cache")
local database = require("core.database")
local db_path = "/tmp/jve/test_peak_hash_rescue_" .. os.time() .. ".jvp"
os.remove(db_path); os.remove(db_path.."-wal"); os.remove(db_path.."-shm")
assert(database.init(db_path), "database.init failed")
local db = database.get_connection()
db:exec(require("import_schema"))
local project_id = "proj-peak-hash-rescue"
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) VALUES ('%s', 'p', %d, %d, 'passthrough')",
    project_id, now, now))
peak_cache.init_for_project(project_id)

local cache_peak_path = database.get_peak_cache_dir(project_id) .. "/" .. media_id .. ".peaks"
os.execute(string.format("mv %q %q", peak_path, cache_peak_path))

-- -----------------------------------------------------------------------
-- Scenario 1: mtime drift, bytes unchanged → RESCUE
-- -----------------------------------------------------------------------
-- Bump the scratch file's mtime by an hour without touching the bytes.
-- touch -m -t shifts mtime explicitly; the actual content stays put.
local future_mtime = original_mtime + 3600
os.execute(string.format("touch -m -t %s %q",
    os.date("!%Y%m%d%H%M.%S", future_mtime), SCRATCH))
local drifted_mtime = assert(fs_utils.file_mtime(SCRATCH),
    "post-touch mtime read failed")
assert(math.floor(drifted_mtime) > math.floor(original_mtime),
    string.format("touch did not advance mtime (orig=%d, post=%d)",
        math.floor(original_mtime), math.floor(drifted_mtime)))

-- _try_load_existing_for_test must return true: same bytes, refreshed mtime.
local rescued = peak_cache._try_load_existing_for_test(
    media_id, SCRATCH, drifted_mtime, nil)
assert(rescued == true,
    "mtime drifted but bytes unchanged — peaks must be rescued via hash check")

-- Verify the stored mtime was rewritten on disk so the next open hits
-- the fast path. A fresh EMP.PEAK_LOAD creates a new mmap of the file,
-- which reflects the pwrite the rescue path just did (the previous
-- mmap is MAP_PRIVATE so its snapshot doesn't update, but we're
-- opening a new one here).
local refreshed_handle = assert(EMP.PEAK_LOAD(cache_peak_path))
local refreshed_hdr = assert(EMP.PEAK_HEADER(refreshed_handle))
EMP.PEAK_RELEASE(refreshed_handle)
assert(refreshed_hdr.source_mtime == math.floor(drifted_mtime),
    string.format("stored mtime must be refreshed in place after rescue "
        .. "(want %d, got %d)",
        math.floor(drifted_mtime), refreshed_hdr.source_mtime))
assert(refreshed_hdr.content_hash == original_hash,
    "content_hash must be unchanged by the mtime refresh — only the "
    .. "8-byte mtime field is rewritten")
assert(refreshed_hdr.source_size == original_size,
    "source_size must be unchanged by the mtime refresh")

-- -----------------------------------------------------------------------
-- Scenario 2: bytes actually changed → REJECT
-- -----------------------------------------------------------------------
-- Overwrite the scratch file with a different fixture (different bytes
-- and/or different size). The cache must NOT rescue — must regenerate.
-- We need the cached peak file at a fresh media_id whose underlying
-- media bytes don't match the header, so copy the rescued peaks under
-- a new id and replace the media file underneath.
local FIXTURE_B = env.test_media_path("test_click_48k_stereo.wav")
os.execute(string.format("cp %q %q", FIXTURE_B, SCRATCH))
local new_mtime = assert(fs_utils.file_mtime(SCRATCH),
    "post-overwrite mtime read failed")

local cache_peak_path_b = database.get_peak_cache_dir(project_id)
    .. "/test_peak_cache_hash_rescue_b.peaks"
os.execute(string.format("cp %q %q", cache_peak_path, cache_peak_path_b))

local rejected = peak_cache._try_load_existing_for_test(
    "test_peak_cache_hash_rescue_b", SCRATCH, new_mtime, nil)
assert(rejected == false,
    "bytes changed — peaks must be rejected and deleted (not rescued)")
local still_there = io.open(cache_peak_path_b, "rb")
assert(still_there == nil,
    "rejected peak file must be deleted from disk")

-- Cleanup
database.shutdown()
os.remove(db_path); os.remove(db_path.."-wal"); os.remove(db_path.."-shm")
os.remove(cache_peak_path)
os.remove(SCRATCH)

print("✅ test_peak_cache_hash_rescue passed")
