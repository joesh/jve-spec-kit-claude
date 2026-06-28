-- Feature 027 / ENGINEERING.md Rule 1.3 (no fallbacks) vs Rule 1.14
-- (fail-fast): the two pull in opposite directions on the CRASH path.
--
-- Domain:
--   capture_on_error fires from inside an error-handler. The editor is
--   already unwinding. If the export pipeline raises (disk full, mkdir
--   denied, dkjson encode bug), the right behavior is NOT to make the
--   crash worse — it's to record an actionable log line and let the
--   already-in-progress unwind finish. Hard-asserting on top of an
--   in-progress crash buries the original error under a secondary
--   crash whose stack trace points at the bug reporter, not the real
--   bug.
--
--   Sync/interactive callers (capture_manual via F12) keep fail-fast
--   semantics — the user is sitting there and a hard assert with a
--   clean stack is preferable to a silent miss. This test pins ONLY
--   the crash-path soft-fail.
--
-- Black-box: stub BugReporter.export_capture so it raises, call
-- capture_on_error, assert (1) the call returns nil, (2) the call does
-- not propagate the error, (3) the editor process (this test) is still
-- alive afterwards.

print("=== test_bug_reporter_crash_capture_soft_fail.lua ===")
require("test_env")

local BugReporter = require("bug_reporter")

-- (1) capture_on_error MUST NOT propagate an export failure during
--     crash unwind. Stub export_capture to raise a representative
--     failure (mkdir denied is the canonical disk-side failure).
do
    local original = BugReporter.export_capture
    BugReporter.export_capture = function(_)
        error("json_exporter: mkdir failed: /no/such/dir: Permission denied")
    end

    local ok, ret = pcall(BugReporter.capture_on_error,
        "Simulated upstream crash: timeline_state nil-tracks",
        "stack trace line 1\nstack trace line 2\n")

    BugReporter.export_capture = original

    assert(ok,
        "capture_on_error MUST swallow export failures during crash unwind " ..
        "so the original error survives. Got propagated error: " .. tostring(ret))
    assert(ret == nil,
        "capture_on_error MUST return nil when export fails; got " .. tostring(ret))
end

-- (2) capture_on_error returns the json_path verbatim on success
--     (regression guard: while fixing #1 don't break the happy path).
do
    local original = BugReporter.export_capture
    BugReporter.export_capture = function(_) return "/tmp/capture-fake/capture.json" end
    local ret = BugReporter.capture_on_error("Test error", "Test stack")
    BugReporter.export_capture = original
    assert(ret == "/tmp/capture-fake/capture.json",
        "capture_on_error MUST return the json_path verbatim on success; got " ..
        tostring(ret))
end

-- (3) The process is still alive — this print runs.
print("✅ test_bug_reporter_crash_capture_soft_fail.lua passed")
