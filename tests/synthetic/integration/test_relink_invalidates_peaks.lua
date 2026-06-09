-- Domain behavior under test:
--
-- After a media row's linked file is changed (RelinkClips, importer, etc),
-- the waveform peak data shown for clips of that media must reflect the
-- newly-linked file. Two failure modes:
--
--   1. Stale peaks: cache holds an in-memory handle and never re-evaluates.
--      User sees waveforms from the file that no longer plays back.
--
--   2. Spurious regeneration: cache re-decodes the file even though
--      nothing about the bytes changed (only the path moved, OR the
--      project was just closed and reopened with the .peaks files still
--      on disk). On a 500-file project that's a multi-minute "rebuild
--      the cache" experience the user shouldn't pay for.
--
-- The test is structured around counting EMP.PEAK_REQUEST invocations,
-- which is the direct signal of "we asked for a fresh decode." Each
-- scenario asserts the exact delta in request count we expect.
--
-- Why a regression test exists here:
-- The session that surfaced this had the editor re-decoding hundreds of
-- audio files every time the user reopened the project or finished a
-- DRP import + relink. Restarting the editor "fixed" stale waveforms,
-- which was masking that the cache wasn't being trusted across reloads.

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()

print("--- test_relink_invalidates_peaks ---")

-- Two distinguishable audio files: click is 144000 samples (3s at 48kHz);
-- tone is 96000 samples (2s). Different lengths give us a header-shape
-- signature so we can prove which file the peaks describe.
local CLICK_WAV = env.test_media_path("test_click_48k_stereo.wav")
local TONE_WAV  = env.test_media_path("test_tone_48k_stereo.wav")
local CLICK_SAMPLES = 144000

-- Step 5 below relies on TONE_WAV.mtime ≠ CLICK_WAV.mtime so the peak
-- cache's mtime invalidation fires when content swaps. Both fixtures
-- live in the repo and `git checkout` restores them to whatever second
-- the checkout ran in — identical mtimes are the norm, not the
-- exception. Touch TONE_WAV forward by 2s so the precondition holds
-- regardless of how the fixtures got onto disk. Real users editing one
-- file at a time naturally produce distinct mtimes; this just makes the
-- test self-healing instead of fixture-state-dependent.
do
    local touch_cmd = string.format(
        "touch -t $(date -r $(( $(stat -f %%m %q) + 2 )) +%%Y%%m%%d%%H%%M.%%S) %q",
        CLICK_WAV, TONE_WAV)
    local ok = os.execute(touch_cmd)
    -- os.execute return varies across Lua flavors; verify by reading
    -- the actual mtimes back instead of trusting the exit code.
    assert(ok ~= nil, "touch shellout failed entirely")
    local fs_utils_setup = require("core.fs_utils")
    local cm = assert(fs_utils_setup.file_mtime(CLICK_WAV))
    local tm = assert(fs_utils_setup.file_mtime(TONE_WAV))
    assert(math.floor(tm) > math.floor(cm), string.format(
        "test setup: TONE_WAV mtime must be > CLICK_WAV mtime "
        .. "(click=%d tone=%d) — without that, the cache's mtime "
        .. "invalidation never fires and step 5 cannot distinguish "
        .. "relink-to-new-content from re-init-of-same-content",
        math.floor(cm), math.floor(tm)))
end

local function peak_bins_at(path)
    local handle = assert(EMP.PEAK_LOAD(path),
        "PEAK_LOAD failed for peak file at " .. tostring(path))
    local hdr = assert(EMP.PEAK_HEADER(handle), "PEAK_HEADER returned nil")
    assert(hdr.bins_per_level and hdr.bins_per_level[1],
        "PEAK_HEADER did not expose bins_per_level[1]")
    local bins = hdr.bins_per_level[1]
    EMP.PEAK_RELEASE(handle)
    return bins
end

-- ---------------------------------------------------------------------------
-- PEAK_REQUEST counter — the "did the cache rebuild?" signal. Wrap the
-- C function via the Lua table binding; peak_cache references EMP.PEAK_REQUEST
-- through the same table, so it sees the counting wrapper.
-- ---------------------------------------------------------------------------
local request_count = 0
local request_log = {}  -- {[i] = {media_id, media_path}} — surfaces *which*
                        -- gen requests fired when the count is wrong.
local original_peak_request = EMP.PEAK_REQUEST
EMP.PEAK_REQUEST = function(media_id, media_path, output_path)
    request_count = request_count + 1
    request_log[request_count] = { media_id = media_id, media_path = media_path }
    return original_peak_request(media_id, media_path, output_path)
end

local function take_request_count_delta(label)
    local n = request_count
    request_count = 0
    request_log = {}
    return n, label
end

-- ---------------------------------------------------------------------------
-- Setup: minimal project + one audio media row + a master sequence so
-- the V13 graph is coherent (RelinkClips' Media.mark_dirty path expects
-- it). We start with the row pointing at an OFFLINE path so init_for_project
-- doesn't request gen here — that lets later steps assert clean deltas.
-- ---------------------------------------------------------------------------
local database = require("core.database")
local Media = require("models.media")
local Sequence = require("models.sequence")
local command_manager = require("core.command_manager")
local Command = require("command")
local peak_cache = require("core.media.peak_cache")
local fs_utils = require("core.fs_utils")

local TEST_DB = "/tmp/jve/test_relink_invalidates_peaks.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB), "database.init failed")

local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-relink-peaks"
local media_id = "media-relink-peaks"

db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings) "
    .. "VALUES ('%s', 'p', 'resample', %d, %d, '{}')",
    project_id, now, now))

-- Peak cache directory is project-scoped; a prior run leaves
-- <cache_dir>/<media_id>.peaks on disk with an embedded source mtime.
-- Without removing it, step 2's "first gen for this media_id" assertion
-- runs against a stale peak file whose embedded mtime matches the current
-- fixture mtime, so try_load_existing reuses instead of regenerating.
-- get_peak_cache_dir requires the project to exist, so this must run AFTER
-- the INSERT above.
do
    local stale_peak_dir = assert(database.get_peak_cache_dir(project_id),
        "test setup: database.get_peak_cache_dir must return a path "
        .. "(stale peak files from prior runs would otherwise persist and "
        .. "invalidate the regen-detection assertions)")
    os.execute(string.format("rm -rf %q", stale_peak_dir))
end

-- DRP-import scenario: media row points at a path that doesn't exist
-- locally (e.g., /Volumes/X/... when X isn't mounted). Use a sentinel
-- under /tmp/jve that we never create.
local OFFLINE_PATH = "/tmp/jve/test_relink_invalidates_peaks_offline_simulated.wav"
os.remove(OFFLINE_PATH)
assert(not fs_utils.file_exists(OFFLINE_PATH),
    "setup precondition: OFFLINE_PATH must not exist")

local media = Media.create({
    id = media_id, project_id = project_id,
    file_path = OFFLINE_PATH, name = "drp-imported",
    duration_frames = CLICK_SAMPLES,
    fps_numerator = 48000, fps_denominator = 1,
    audio_sample_rate = 48000, audio_channels = 2,
    width = 0, height = 0, codec = "pcm_s16le",
    -- Sequence.ensure_master asserts audio_tc origin is present. Real
    -- DRP imports populate this from the file's BWF time_reference; the
    -- value is irrelevant for this test, just present + non-nil.
    metadata = '{"start_tc_audio_samples":0,"start_tc_audio_rate":48000}',
})
assert(media:save(), "media:save failed")
Sequence.ensure_master(media_id, project_id)
command_manager.init_project_only(project_id)

local function wait_for_status(mid, target, deadline_s)
    -- Drive the try_finalize_generating path each tick; in --test mode
    -- the Qt poll timer doesn't fire on its own. Path/mtime args are
    -- ignored by ensure_peaks when generation_status is "generating".
    local mtime = assert(fs_utils.file_mtime(CLICK_WAV),
        "wait_for_status: CLICK_WAV fixture must be present on disk")
    local deadline = os.time() + deadline_s
    while os.time() <= deadline do
        local s = peak_cache.get_status(mid)
        if s == target then return true end
        if s == "failed" then return false end
        os.execute("sleep 0.1")
        peak_cache.ensure_peaks(mid, CLICK_WAV, mtime, nil)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Step 1: cold init while media is offline. No gen requests should fire —
-- file_exists() short-circuits init_for_project before ensure_peaks runs.
-- ---------------------------------------------------------------------------
print("  step 1: init_for_project with offline media — no gen requested")
peak_cache.init_for_project(project_id)
local n1 = take_request_count_delta("step1")
assert(n1 == 0, string.format(
    "init with offline media should NOT request gen, got %d request(s)", n1))
assert(peak_cache.get_status(media_id) == "none",
    "offline media should report status='none' after init")

-- ---------------------------------------------------------------------------
-- Step 2: relink to CLICK_WAV. This is the FIRST time peaks could be
-- generated for this media_id, so exactly 1 request is expected.
-- ---------------------------------------------------------------------------
print("  step 2: relink offline → CLICK_WAV — exactly 1 gen request")
do
    local cmd = Command.create("RelinkClips", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("clip_relink_map", {})
    cmd:set_parameter("media_path_changes", { [media_id] = CLICK_WAV })
    local result = command_manager.execute(cmd)
    assert(result.success, "RelinkClips failed: " .. tostring(result.error_message))
end
assert(wait_for_status(media_id, "complete", 30),
    "click peak gen did not complete within 30s")
local n2 = take_request_count_delta("step2")
assert(n2 == 1, string.format(
    "relink to CLICK_WAV should request exactly 1 gen, got %d", n2))

local cache_dir = database.get_peak_cache_dir(project_id)
local peak_path = cache_dir .. "/" .. media_id .. ".peaks"
local bins_click = peak_bins_at(peak_path)
assert(bins_click > 100, string.format(
    "click peaks should report a meaningful bin count, got %d", bins_click))

-- ---------------------------------------------------------------------------
-- Step 3: simulate "close + reopen" while peaks are valid on disk. clear()
-- drops in-memory state; init_for_project should reload from disk via
-- try_load_existing's mtime check. ZERO gen requests expected.
--
-- This is the user's actual complaint shape: opening a project where
-- .peaks files already exist must not pay the regeneration cost.
-- ---------------------------------------------------------------------------
print("  step 3: clear + re-init — peaks reused from disk, no regen")
peak_cache.clear()
peak_cache.init_for_project(project_id)
local n3 = take_request_count_delta("step3")
assert(n3 == 0, string.format(
    "REGRESSION: re-init with valid on-disk peaks should NOT regen, got "
    .. "%d request(s). Request log: %s",
    n3, (function()
        local parts = {}
        for i, r in ipairs(request_log) do
            parts[i] = string.format("[%d]=%s", i, r.media_id)
        end
        return table.concat(parts, ", ")
    end)()))
assert(peak_cache.get_status(media_id) == "complete",
    "after re-init, status must be 'complete' (peaks loaded from disk)")

-- And the visible-peaks path — what the renderer actually calls — must
-- return data immediately, with no gen pending.
local peaks, count = peak_cache.get_visible_peaks(media_id, 0, CLICK_SAMPLES, 100)
assert(peaks ~= nil and count == 100, string.format(
    "after re-init, get_visible_peaks must return peaks (got peaks=%s count=%s)",
    tostring(peaks), tostring(count)))

-- ---------------------------------------------------------------------------
-- Step 4: relink to a path with the SAME content as CLICK_WAV (cp -p
-- preserves mtime — DRP-import → media-manage scenario where the bytes
-- moved but the file is the same recording). Header-mtime cross-check
-- in try_load_existing should reuse the existing peak file. ZERO gen
-- requests expected.
-- ---------------------------------------------------------------------------
print("  step 4: relink to byte-identical copy — peaks reused, no regen")
local CLICK_COPY = "/tmp/jve/test_relink_invalidates_peaks_click_copy.wav"
os.remove(CLICK_COPY)
os.execute(string.format("cp -p %q %q", CLICK_WAV, CLICK_COPY))
-- Half-2 check: validate cp produced the file with the source's mtime.
-- os.execute's return semantics differ across Lua 5.1 / 5.2 / LuaJIT, so
-- assert on the actual outcome (file present + mtime preserved) instead
-- of trusting the exit code.
local src_mtime = assert(fs_utils.file_mtime(CLICK_WAV),
    "fixture must have an mtime")
local copy_mtime = assert(fs_utils.file_mtime(CLICK_COPY),
    "cp -p didn't produce the copy at " .. CLICK_COPY)
assert(math.floor(src_mtime) == math.floor(copy_mtime), string.format(
    "cp -p must preserve mtime to second resolution (src=%d copy=%d) "
    .. "— without that, try_load_existing's mtime check would invalidate "
    .. "the peak file and step 4's no-regen assertion would be vacuous",
    math.floor(src_mtime), math.floor(copy_mtime)))
do
    local cmd = Command.create("RelinkClips", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("clip_relink_map", {})
    cmd:set_parameter("media_path_changes", { [media_id] = CLICK_COPY })
    local result = command_manager.execute(cmd)
    assert(result.success, "RelinkClips failed: " .. tostring(result.error_message))
end
local n4 = take_request_count_delta("step4")
assert(n4 == 0, string.format(
    "REGRESSION: relink to byte-identical file (same mtime) regenerated "
    .. "peaks unnecessarily — got %d request(s). The bytes haven't changed; "
    .. "the header-mtime cross-check should have reused the existing peaks.",
    n4))
assert(peak_cache.get_status(media_id) == "complete",
    "after same-content relink, status must remain 'complete'")
local peaks4, count4 = peak_cache.get_visible_peaks(media_id, 0, CLICK_SAMPLES, 100)
assert(peaks4 ~= nil and count4 == 100,
    "after same-content relink, get_visible_peaks must keep returning peaks")

-- ---------------------------------------------------------------------------
-- Step 5: relink to a genuinely different file (TONE_WAV, different bytes
-- AND different mtime). Exactly 1 gen request expected — and the resulting
-- peak file must describe the tone, not the click.
-- ---------------------------------------------------------------------------
print("  step 5: relink to different content — exactly 1 gen request")
do
    local cmd = Command.create("RelinkClips", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("clip_relink_map", {})
    cmd:set_parameter("media_path_changes", { [media_id] = TONE_WAV })
    local result = command_manager.execute(cmd)
    assert(result.success, "RelinkClips failed: " .. tostring(result.error_message))
end
assert(wait_for_status(media_id, "complete", 30),
    "tone peak gen did not complete within 30s")
local n5 = take_request_count_delta("step5")
assert(n5 == 1, string.format(
    "relink to different content should request exactly 1 gen, got %d", n5))
local bins_tone = peak_bins_at(peak_path)
assert(bins_tone < bins_click, string.format(
    "post-relink peaks should describe the (shorter) tone WAV "
    .. "(bins=%d should be < click's %d)", bins_tone, bins_click))

-- ---------------------------------------------------------------------------
-- Step 6: another close+reopen, this time after the peaks describe TONE.
-- Same expectation as step 3: no regen.
-- ---------------------------------------------------------------------------
print("  step 6: clear + re-init after content change — still no regen")
peak_cache.clear()
peak_cache.init_for_project(project_id)
local n6 = take_request_count_delta("step6")
assert(n6 == 0, string.format(
    "re-init after content change should reuse new on-disk peaks, "
    .. "got %d request(s)", n6))
assert(peak_cache.get_status(media_id) == "complete",
    "after second re-init, status must be 'complete'")

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
EMP.PEAK_REQUEST = original_peak_request
os.remove(CLICK_COPY)
peak_cache.clear()
database.shutdown()
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
os.execute(string.format("rm -rf %q", cache_dir))

print("✅ test_relink_invalidates_peaks passed")
