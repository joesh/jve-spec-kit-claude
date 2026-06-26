-- Feature 027 T026: pending_queue cap + drain semantics (amended FR-024).
--
-- Cap path: insert 50 pending pairs, enqueue the 51st → oldest is
-- deleted, new is inserted, a queue-cap-warning signal fires.
-- Drain success (200): pair deleted, no user-visible warning.
-- Drain rate-limit (429 during drain): pair deleted, log-only.
-- Drain transport error: pair left in place.
-- Drain order: oldest-first by mtime.

require("test_env")

local function require_or_red(modname, task)
    local ok, mod = pcall(require, modname)
    if not ok then
        error("RED — " .. modname .. " unloadable (" .. task .. " not landed): " .. tostring(mod))
    end
    return mod
end

local pending_queue = require_or_red("bug_reporter.pending_queue", "T036")
local signals = require("core.signals")

local TMP = "/tmp/jve_pending_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)
if type(pending_queue.set_root_for_tests) == "function" then
    pending_queue.set_root_for_tests(TMP)
else
    error("RED — pending_queue.set_root_for_tests missing; T036 must expose a test-only root override")
end

local INSTALL_ID = "550e8400-e29b-41d4-a716-446655440000"
local NONCE = string.rep("a", 64)

local function count_files()
    local p = io.popen("/bin/ls -1 " .. TMP .. " 2>/dev/null | /usr/bin/wc -l")
    local n = tonumber(p:read("*l"))
    p:close()
    return n
end

-- (1) Cap path: 50 entries + the 51st triggers a cap-warning signal.
do
    pending_queue.clear_all_for_tests()
    for i = 1, 50 do
        pending_queue.enqueue(("zip_" .. i):rep(10), '{"i":' .. i .. '}')
    end
    local warning_fired = false
    local dropped_id_observed
    signals.connect("bug_report_queue_cap_warning", function(payload)
        warning_fired = true
        dropped_id_observed = payload and payload.dropped_id
    end)
    pending_queue.enqueue("zip_51", '{"i":51}')
    assert(warning_fired,
        "queue cap warning signal must fire when count exceeds 50")
    assert(dropped_id_observed,
        "cap warning payload must include dropped_id")
    -- After the cap drop + new insert, count is exactly 50 pairs (each
    -- pair is two files, .payload.zip + .metadata.json → 100 files).
    -- Confirm via file count.
    local n = count_files()
    assert(n == 100, "expected 100 files (50 pairs) after cap drop, got " .. tostring(n))
end

-- (2) Drain success — 200 → all pairs deleted silently.
do
    pending_queue.clear_all_for_tests()
    pending_queue.enqueue("zipA", '{"a":1}')
    pending_queue.enqueue("zipB", '{"b":2}')
    pending_queue.enqueue("zipC", '{"c":3}')
    local user_visible_count = 0
    signals.connect("bug_report_drain_warning", function() user_visible_count = user_visible_count + 1 end)
    -- Stub transport.post_report → always 200.
    package.loaded["bug_reporter.transport"] = {
        post_report = function() return { ok = true, code = nil } end,
    }
    pending_queue.drain(INSTALL_ID, NONCE)
    assert(count_files() == 0, "all pairs must be deleted after 200 drain")
    assert(user_visible_count == 0,
        "drain success is silent — no user-visible warning expected (FR-024)")
end

-- (3) Drain rate-limit (429 during drain) → pair deleted, log-only.
do
    pending_queue.clear_all_for_tests()
    pending_queue.enqueue("zipD", '{"d":1}')
    local user_visible_count = 0
    signals.connect("bug_report_drain_warning", function() user_visible_count = user_visible_count + 1 end)
    package.loaded["bug_reporter.transport"] = {
        post_report = function() return { ok = false, code = "rate_limited" } end,
    }
    pending_queue.drain(INSTALL_ID, NONCE)
    assert(count_files() == 0,
        "rate-limited drain still deletes the pair per amended FR-024 (drain-time 429 is log-only)")
    assert(user_visible_count == 0,
        "rate-limit during drain must NOT surface a user-visible warning")
end

-- (4) Drain transport error → pair STAYS in place.
do
    pending_queue.clear_all_for_tests()
    pending_queue.enqueue("zipE", '{"e":1}')
    package.loaded["bug_reporter.transport"] = {
        post_report = function() return { ok = false, code = "transport" } end,
    }
    pending_queue.drain(INSTALL_ID, NONCE)
    local n = count_files()
    assert(n == 2,
        "transport-error during drain MUST leave pair in place; got " .. tostring(n) .. " files")
end

-- (5) Drain order: oldest-first by mtime.
do
    pending_queue.clear_all_for_tests()
    pending_queue.enqueue("zipF1", '{"f":1}'); os.execute("/bin/sleep 1")
    pending_queue.enqueue("zipF2", '{"f":2}'); os.execute("/bin/sleep 1")
    pending_queue.enqueue("zipF3", '{"f":3}')
    local order = {}
    package.loaded["bug_reporter.transport"] = {
        post_report = function(metadata_json) order[#order + 1] = metadata_json; return { ok = true } end,
    }
    pending_queue.drain(INSTALL_ID, NONCE)
    assert(#order == 3, "all 3 pairs must be attempted")
    -- order[1] must be F1's metadata, order[3] must be F3's.
    assert(order[1]:find('"f":1'), "first drain call MUST be the oldest pair (F1)")
    assert(order[3]:find('"f":3'), "last drain call MUST be the newest pair (F3)")
end

os.execute("/bin/rm -rf " .. TMP)
print("✅ test_bug_reporter_queue_cap_and_drain.lua passed")
