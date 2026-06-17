-- Peak generation under FD pressure: the background generator must cap
-- the number of concurrently-running jobs so file-descriptor usage stays
-- bounded. Without admission control, opening a project with hundreds of
-- audio media exhausted the OS FD table and cascaded into icon-load
-- failures that killed editor startup.

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()

print("--- test_peak_gen_admission ---")

assert(type(EMP.PEAK_RUNNING_COUNT) == "function",
    "PEAK_RUNNING_COUNT binding required for admission observability")
assert(type(EMP.PEAK_MAX_RUNNING) == "function",
    "PEAK_MAX_RUNNING binding required (surfaces the admission cap)")

local MAX_RUNNING = EMP.PEAK_MAX_RUNNING()
assert(type(MAX_RUNNING) == "number" and MAX_RUNNING > 0,
    string.format("PEAK_MAX_RUNNING must be a positive integer, got %s",
        tostring(MAX_RUNNING)))
print(string.format("  admission cap: %d", MAX_RUNNING))

-- Queue enough jobs to exceed the cap. Use the same source file with
-- distinct media_ids so the generator treats each as its own job.
local SOURCE = env.test_media_path("A005_C052_0925BL_001.mp4")
local OUT_DIR = "/tmp/jve/test_peak_admission"
os.execute(string.format("rm -rf %q && mkdir -p %q", OUT_DIR, OUT_DIR))

local NUM_JOBS = MAX_RUNNING * 4
for i = 1, NUM_JOBS do
    EMP.PEAK_REQUEST(string.format("admission_%03d", i),
        SOURCE, string.format("%s/admission_%03d.peaks", OUT_DIR, i), -1)  -- composite
end

-- Poll while jobs are in flight; running count must never exceed the cap.
local peak_running = 0
local deadline = os.time() + 30
while os.time() <= deadline do
    local running = EMP.PEAK_RUNNING_COUNT()
    assert(type(running) == "number", "PEAK_RUNNING_COUNT must return a number")
    assert(running <= MAX_RUNNING, string.format(
        "admission cap violated: running=%d > max=%d", running, MAX_RUNNING))
    if running > peak_running then peak_running = running end

    -- Count finished jobs.
    local done = 0
    for i = 1, NUM_JOBS do
        local status = EMP.PEAK_STATUS(string.format("admission_%03d", i))
        if status and (status.state == "complete" or status.state == "failed") then
            done = done + 1
        end
    end
    if done == NUM_JOBS then break end

    -- Yield briefly — coarse sleep to avoid spinning.
    for _ = 1, 200000 do end
end

-- Diagnostic: dump final state.
local counts = { complete = 0, failed = 0, generating = 0, queued = 0, none = 0 }
for i = 1, NUM_JOBS do
    local status = EMP.PEAK_STATUS(string.format("admission_%03d", i))
    local s = status and status.state or "none"
    counts[s] = (counts[s] or 0) + 1
end
print(string.format("  final: complete=%d failed=%d generating=%d queued=%d running_count=%d",
    counts.complete, counts.failed, counts.generating, counts.queued,
    EMP.PEAK_RUNNING_COUNT()))

-- Final state: every job reached a terminal state, running count is 0, and
-- at some point we saw at least one slot in use (the generator actually ran).
assert(EMP.PEAK_RUNNING_COUNT() == 0, string.format(
    "after all jobs finished, running count must be 0; got %d",
    EMP.PEAK_RUNNING_COUNT()))
assert(peak_running > 0,
    "admission test did not observe any running jobs — generator stalled?")

for i = 1, NUM_JOBS do
    local status = EMP.PEAK_STATUS(string.format("admission_%03d", i))
    assert(status, string.format("job %d has no status", i))
    assert(status.state == "complete" or status.state == "failed",
        string.format("job %d still %s after deadline", i, status.state))
end

print(string.format("  queued %d jobs, peak concurrent running = %d (cap = %d)",
    NUM_JOBS, peak_running, MAX_RUNNING))
print("✅ test_peak_gen_admission passed")
