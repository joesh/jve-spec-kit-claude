-- Integration: PEAK_CANCEL_ALL must let a subsequent PEAK_REQUEST for
-- the same media_id start a fresh job at a NEW output_path.
--
-- Regression: PeakGenerator::CancelAll() set cancel_flag on each job
-- but did NOT remove them from m_jobs. PeakGenerator::RequestPeaks is
-- idempotent on the {media_id : state != None} pair, so the next
-- request silently skipped — the old job's output_path was retained.
-- In production this surfaced as a peak-cache warning storm after
-- project_changed: workers finalised completed jobs into the OLD
-- project's cache_dir, and the NEW project's poll loaded paths from
-- its NEW cache_dir → "failed to open peak file" (false-positive
-- failure on the new project's peak load).
--
-- The CancelPeaks(media_id) variant has always erased the entry —
-- this test pins CancelAll to the same policy.

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local fs_utils = require("core.fs_utils")

print("--- test_peak_gen_cancel_all_re_request ---")

local SOURCE = env.test_media_path("A005_C052_0925BL_001.mp4")
local OUT_DIR = "/tmp/jve/test_peak_cancel_all_re_request"
os.execute(string.format("rm -rf %q && mkdir -p %q", OUT_DIR, OUT_DIR))

local MEDIA_ID = "cancel_re_request_media"
local OLD_PATH = OUT_DIR .. "/old.peaks"
local NEW_PATH = OUT_DIR .. "/new.peaks"

local function wait_until_done(media_id, deadline_seconds)
    local deadline = os.time() + deadline_seconds
    while os.time() <= deadline do
        local status = EMP.PEAK_STATUS(media_id)
        if status and (status.state == "complete" or status.state == "failed") then
            return status.state
        end
        for _ = 1, 200000 do end  -- coarse yield
    end
    return "timeout"
end

-- ── (1) Request + complete at OLD_PATH ────────────────────────────────
print("(1) request at OLD_PATH, wait for completion")
EMP.PEAK_REQUEST(MEDIA_ID, SOURCE, OLD_PATH)
local state1 = wait_until_done(MEDIA_ID, 30)
assert(state1 == "complete", string.format(
    "first peak gen must complete; got %s", tostring(state1)))
assert(fs_utils.file_exists(OLD_PATH), string.format(
    "OLD_PATH must exist after first job; got missing %s", OLD_PATH))
print("  PASS first job wrote OLD_PATH")

-- ── (2) PEAK_CANCEL_ALL ───────────────────────────────────────────────
print("(2) PEAK_CANCEL_ALL")
EMP.PEAK_CANCEL_ALL()

-- ── (3) Re-request SAME media_id with NEW_PATH ───────────────────────
-- After CancelAll, the next request for media_id MUST start a fresh
-- job that targets NEW_PATH. Pre-fix, RequestPeaks's idempotent skip
-- on state != None kept the old job (state = Complete, output_path =
-- OLD_PATH) and silently dropped this request. The on-disk symptom
-- was: PEAK_STATUS returns "complete" almost instantly (no actual
-- regen happened) and NEW_PATH never gets written.
print("(3) re-request SAME media_id with NEW_PATH")
assert(not fs_utils.file_exists(NEW_PATH),
    "fixture: NEW_PATH must not exist before re-request")
EMP.PEAK_REQUEST(MEDIA_ID, SOURCE, NEW_PATH)
local state2 = wait_until_done(MEDIA_ID, 30)
assert(state2 == "complete", string.format(
    "re-requested peak gen must complete (not skip); got %s",
    tostring(state2)))
assert(fs_utils.file_exists(NEW_PATH), string.format(
    "NEW_PATH must exist after re-request — if missing, CancelAll "
    .. "did not let RequestPeaks start a fresh job (the old job's "
    .. "output_path was retained). NEW_PATH=%s", NEW_PATH))
print("  PASS re-request wrote NEW_PATH")

print("\nPASS test_peak_gen_cancel_all_re_request")
