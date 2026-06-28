-- Feature 027: pending_queue cap + drain semantics (amended FR-024, async).
--
-- Cap path: insert 50 pending pairs, enqueue the 51st → oldest is
-- deleted, new is inserted, a queue-cap-warning signal fires.
-- Drain success (200): pair deleted, no user-visible warning.
-- Drain rate-limit (429 during drain): pair deleted, log-only.
-- Drain transport error: pair left in place; drain stops.
-- Drain order: oldest-first by mtime.
-- enqueue REQUIRES local_id (idempotency: the same id MUST be reused
-- on every retry so the Worker can dedup a first attempt whose
-- response was lost on the wire).

require("test_env")

local pending_queue = require("bug_reporter.pending_queue")
local signals = require("core.signals")

local TMP = "/tmp/jve_pending_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)
pending_queue.set_root_for_tests(TMP)

local INSTALL_ID = "550e8400-e29b-41d4-a716-446655440000"
local NONCE = string.rep("a", 64)

local function count_files()
    local p = io.popen("/bin/ls -1 " .. TMP .. " 2>/dev/null | /usr/bin/wc -l")
    local n = tonumber(p:read("*l"))
    p:close()
    return n
end

local function uid(label) return "id-" .. label end

-- (1) Cap path
pending_queue.clear_all_for_tests()
for i = 1, 50 do
    pending_queue.enqueue(("zip_" .. i):rep(10), '{"i":' .. i .. '}', uid(tostring(i)))
end
local warning_fired = false
local dropped_id_observed
signals.connect("bug_report_queue_cap_warning", function(payload)
    warning_fired = true
    dropped_id_observed = payload and payload.dropped_id
end)
pending_queue.enqueue("zip_51", '{"i":51}', uid("51"))
assert(warning_fired, "queue cap warning signal must fire when count exceeds 50")
assert(dropped_id_observed, "cap warning payload must include dropped_id")
assert(count_files() == 100, "expected 100 files (50 pairs) after cap drop, got " .. tostring(count_files()))

-- enqueue MUST refuse a missing local_id (idempotency invariant).
local ok_no_id = pcall(pending_queue.enqueue, "zipX", '{"x":1}')
assert(not ok_no_id, "enqueue without local_id must assert")

-- (2) Drain success — 200 → all pairs deleted silently.
pending_queue.clear_all_for_tests()
pending_queue.enqueue("zipA", '{"a":1}', uid("A"))
pending_queue.enqueue("zipB", '{"b":2}', uid("B"))
pending_queue.enqueue("zipC", '{"c":3}', uid("C"))
package.loaded["bug_reporter.transport"] = {
    post_report = function(_meta, _zip, _local_id, _install, _nonce, on_done)
        on_done({ ok = true })
    end,
}
local drain_done = false
pending_queue.drain(INSTALL_ID, NONCE, function() drain_done = true end)
assert(drain_done, "drain on_done must fire after the last pair completes")
assert(count_files() == 0, "all pairs must be deleted after 200 drain")

-- (3) Drain rate-limit (429 during drain) → pair deleted, log-only, drain continues.
pending_queue.clear_all_for_tests()
pending_queue.enqueue("zipD", '{"d":1}', uid("D"))
package.loaded["bug_reporter.transport"] = {
    post_report = function(_m, _z, _l, _i, _n, on_done) on_done({ ok = false, code = "rate_limited" }) end,
}
drain_done = false
pending_queue.drain(INSTALL_ID, NONCE, function() drain_done = true end)
assert(drain_done)
assert(count_files() == 0,
    "rate-limited drain still deletes the pair per amended FR-024 (drain-time 429 is log-only)")

-- (4) Drain transport error → pair STAYS in place; drain stops.
pending_queue.clear_all_for_tests()
pending_queue.enqueue("zipE", '{"e":1}', uid("E"))
package.loaded["bug_reporter.transport"] = {
    post_report = function(_m, _z, _l, _i, _n, on_done) on_done({ ok = false, code = "transport" }) end,
}
drain_done = false
pending_queue.drain(INSTALL_ID, NONCE, function() drain_done = true end)
assert(drain_done)
assert(count_files() == 2,
    "transport-error during drain MUST leave pair in place; got " .. tostring(count_files()) .. " files")

-- (5) Drain order: oldest-first by mtime. drain MUST pass the entry's
-- local_id (== filename uuid) as the X-Report-Local-Id so the same id
-- is used on every retry (Worker idempotency).
pending_queue.clear_all_for_tests()
pending_queue.enqueue("zipF1", '{"f":1}', uid("F1")); os.execute("/bin/sleep 1")
pending_queue.enqueue("zipF2", '{"f":2}', uid("F2")); os.execute("/bin/sleep 1")
pending_queue.enqueue("zipF3", '{"f":3}', uid("F3"))
local seen_metadata = {}
local seen_local_ids = {}
package.loaded["bug_reporter.transport"] = {
    post_report = function(metadata, _zip, local_id, _i, _n, on_done)
        seen_metadata[#seen_metadata + 1] = metadata
        seen_local_ids[#seen_local_ids + 1] = local_id
        on_done({ ok = true })
    end,
}
pending_queue.drain(INSTALL_ID, NONCE, function() end)
assert(#seen_metadata == 3, "all 3 pairs must be attempted")
assert(seen_metadata[1]:find('"f":1'), "first drain call MUST be the oldest pair (F1)")
assert(seen_metadata[3]:find('"f":3'), "last drain call MUST be the newest pair (F3)")
assert(seen_local_ids[1] == uid("F1") and seen_local_ids[3] == uid("F3"),
    "drain MUST pass the stored entry id as X-Report-Local-Id (idempotency)")

os.execute("/bin/rm -rf " .. TMP)
print("✅ test_bug_reporter_queue_cap_and_drain.lua passed")
