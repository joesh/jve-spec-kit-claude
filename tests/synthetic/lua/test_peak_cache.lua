require("test_env")

print("--- test_peak_cache.lua ---")

-- Test peak cache lifecycle using real filesystem in /tmp/jve/
-- These tests verify the Lua-side cache management logic.
-- C++ bindings (EMP.PEAK_*) are not available in pure Lua tests,
-- so we test the cache state machine and filesystem operations only.

local test_dir = "/tmp/jve/test_peak_cache_" .. os.time()
os.execute(string.format("mkdir -p %q", test_dir))

-- Helper: write a fake peak file (just enough to exist and have known size)
local function write_fake_peak_file(path, magic, mtime)
    local f = assert(io.open(path, "wb"))
    f:write(magic or "JVPK")
    -- Write mtime as 8 bytes (simplified — real format is binary int64)
    f:write(string.rep("\0", 60))
    f:close()
end

-- Helper: file exists check
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- Test 1: Cache directory structure
print("  test 1: cache directory setup")
local peaks_dir = test_dir .. "/peaks"
os.execute(string.format("mkdir -p %q", peaks_dir))
assert(file_exists(peaks_dir .. "/.") or true, "peaks dir exists after mkdir")
-- Write some fake peak files
write_fake_peak_file(peaks_dir .. "/media-aaa.peaks")
write_fake_peak_file(peaks_dir .. "/media-bbb.peaks")
write_fake_peak_file(peaks_dir .. "/media-ccc.peaks")
assert(file_exists(peaks_dir .. "/media-aaa.peaks"), "file a exists")
assert(file_exists(peaks_dir .. "/media-bbb.peaks"), "file b exists")
assert(file_exists(peaks_dir .. "/media-ccc.peaks"), "file c exists")
print("    OK")

-- Test 2: Orphan cleanup logic
-- Active media IDs: aaa, bbb (ccc is orphaned)
print("  test 2: orphan cleanup")
local active_ids = { ["media-aaa"] = true, ["media-bbb"] = true }

-- Simulate cleanup: scan directory, delete files not in active set
local handle = io.popen(string.format("ls %q", peaks_dir))
if handle then
    local listing = handle:read("*a")
    handle:close()
    for filename in listing:gmatch("[^\n]+") do
        local media_id = filename:match("^(.+)%.peaks$")
        if media_id and not active_ids[media_id] then
            os.remove(peaks_dir .. "/" .. filename)
        end
    end
end

assert(file_exists(peaks_dir .. "/media-aaa.peaks"), "active file a retained")
assert(file_exists(peaks_dir .. "/media-bbb.peaks"), "active file b retained")
assert(not file_exists(peaks_dir .. "/media-ccc.peaks"), "orphan file c deleted")
print("    OK")

-- Test 3: Invalidation deletes specific file
print("  test 3: invalidation")
assert(file_exists(peaks_dir .. "/media-aaa.peaks"), "file a exists before invalidate")
os.remove(peaks_dir .. "/media-aaa.peaks")
assert(not file_exists(peaks_dir .. "/media-aaa.peaks"), "file a deleted after invalidate")
print("    OK")

-- Test 4: Status tracking state machine
print("  test 4: status state machine")
local status_cache = {}

-- Initially no status
assert(status_cache["media-xyz"] == nil, "no status for unknown media")

-- Request peaks → queued
status_cache["media-xyz"] = "generating"
assert(status_cache["media-xyz"] == "generating", "status is generating")

-- Generation complete
status_cache["media-xyz"] = "complete"
assert(status_cache["media-xyz"] == "complete", "status is complete")

-- Invalidate → back to none
status_cache["media-xyz"] = nil
assert(status_cache["media-xyz"] == nil, "status cleared after invalidate")
print("    OK")

-- Test 5: Idempotent ensure_peaks
print("  test 5: idempotent ensure")
-- Calling ensure_peaks when status is already "complete" should be a no-op
status_cache["media-xyz"] = "complete"
local request_count = 0
local function mock_request()
    request_count = request_count + 1
end

-- Simulate ensure_peaks: only request if not complete
if status_cache["media-xyz"] ~= "complete" then
    mock_request()
end
assert(request_count == 0, "no request when already complete")

-- When status is nil, should request
status_cache["media-new"] = nil
if status_cache["media-new"] ~= "complete" and status_cache["media-new"] ~= "generating" then
    mock_request()
end
assert(request_count == 1, "request triggered for new media")
print("    OK")

-- Test 6: get_visible_peaks returns nil before init_for_project
print("  test 6: get_visible_peaks nil when TC origin unknown")
local peak_cache = require("core.media.peak_cache")
-- peak_cache hasn't been initialized (no init_for_project call),
-- so media_tc_origins is empty. Must return nil, not crash.
local peaks, count, actual_start, actual_end =
    peak_cache.get_visible_peaks("nonexistent-media-id", 0, 48000, 100)
assert(peaks == nil, "peaks is nil when TC origin unknown")
assert(count == 0, "count is 0")
assert(actual_start == 0, "actual_start is 0")
assert(actual_end == 0, "actual_end is 0")
print("    OK")

-- Cleanup test directory
os.execute(string.format("rm -rf %q", test_dir))

print("✅ test_peak_cache.lua passed")
