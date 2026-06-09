-- Contract test (014, T007): background-worker cancel-and-drain semantics.
--
-- Spec ref: contracts/worker_cancel_drain.md, FR-003, FR-003a.
--
-- Domain: workers that write to per-project DB rows must expose two
-- primitives so the pre-switch handler can flush queued writes safely:
--
--   * worker:cancel()                — sets a cancel flag immediately.
--                                       Returns instantly.
--   * worker:wait_for_drain(timeout_ms)
--                                     — blocks the caller for up to
--                                       timeout_ms while queued write
--                                       callbacks complete; returns
--                                       true on drain, false on timeout.
--   * worker:pending_count()         — diagnostic accessor for the
--                                       timeout-warning log line.
--
-- Pre-switch protocol: cancel(), then wait_for_drain(1000). On timeout,
-- log a warning naming the worker and pending_count(); switch proceeds.
--
-- Red today on TWO axes:
--   1. media_status.cancel_background_probe exists, but
--      media_status.wait_for_drain and media_status.pending_count do
--      not. T024 lands them.
--   2. The drain budget contract (1000 ms hard cap) is not yet
--      enforced by any production code path.
--
-- This test verifies the CONTRACT shape using a synthetic worker that
-- implements the spec, and a precondition check that the production
-- worker (media_status) exposes the same surface.
--
-- NSF: every fixture call validates I/O; per-scenario assertions check
-- both halves of the contract (the result AND the postconditions).

require("test_env")

local media_status = require("core.media.media_status")

print("=== test_worker_cancel_drain ===")

-- ----------------------------------------------------------------------
-- Synthetic worker — implements the CONTRACT under test. Each instance
-- has its own queue and completion latch. Test scenarios drive these.
-- ----------------------------------------------------------------------

local function new_synthetic_worker()
    local worker = {
        cancel_flag = false,
        pending = {},          -- callbacks queued but not yet executed
        completed = 0,
    }

    function worker:cancel()
        self.cancel_flag = true
    end

    function worker:queue(write_callback)
        self.pending[#self.pending + 1] = write_callback
    end

    function worker:pending_count()
        return #self.pending
    end

    function worker:wait_for_drain(timeout_ms)
        assert(type(timeout_ms) == "number" and timeout_ms >= 0,
            "wait_for_drain: timeout_ms must be non-negative number")
        local start_ms = os.clock() * 1000
        while #self.pending > 0 do
            -- Drain one queued write per loop iteration. Real workers
            -- drain on their own thread; this synthetic version blocks
            -- the caller exactly the way the contract specifies.
            local cb = table.remove(self.pending, 1)
            cb(self)
            self.completed = self.completed + 1
            local elapsed_ms = (os.clock() * 1000) - start_ms
            if elapsed_ms >= timeout_ms and #self.pending > 0 then
                return false
            end
        end
        return true
    end

    return worker
end

-- ----------------------------------------------------------------------
-- Scenario 1: drain success — every queued write completes within budget.
-- ----------------------------------------------------------------------

do
    local w = new_synthetic_worker()
    for _ = 1, 5 do
        w:queue(function() end)  -- fast no-op; together they finish < 100 ms
    end
    assert(w:pending_count() == 5,
        "scenario 1 setup: pending_count must be 5 before drain")

    w:cancel()
    local drained = w:wait_for_drain(1000)
    assert(drained == true, string.format(
        "DRAIN-SUCCESS CONTRACT: 5 fast writes must drain within 1000 ms\n" ..
        "  budget. wait_for_drain returned %s.", tostring(drained)))
    assert(w:pending_count() == 0, string.format(
        "DRAIN-SUCCESS POSTCONDITION: pending_count must be 0 after drain.\n" ..
        "  Got %d.", w:pending_count()))
    assert(w.completed == 5, string.format(
        "DRAIN-SUCCESS POSTCONDITION: all 5 queued writes must have run.\n" ..
        "  Got completed=%d.", w.completed))
    print("  ✓ drain success: 5 writes completed within budget")
end

-- ----------------------------------------------------------------------
-- Scenario 2: drain timeout — a queued write blocks past the budget.
-- ----------------------------------------------------------------------

do
    local w = new_synthetic_worker()
    -- Queue ONE write that artificially burns 1500 ms of CPU before
    -- returning. With a 1000 ms drain budget, wait_for_drain must
    -- return false. We use os.clock() polling because the test runs
    -- under LuaJIT without a sleep primitive.
    w:queue(function()
        local until_ms = (os.clock() * 1000) + 1500
        while (os.clock() * 1000) < until_ms do end
    end)
    -- Queue two more writes that won't get a chance to run.
    w:queue(function() end)
    w:queue(function() end)

    local before_ms = os.clock() * 1000
    w:cancel()
    local drained = w:wait_for_drain(1000)
    local elapsed_ms = (os.clock() * 1000) - before_ms

    assert(drained == false, string.format(
        "DRAIN-TIMEOUT CONTRACT: a write blocking past the budget must\n" ..
        "  cause wait_for_drain to return false. Got %s.", tostring(drained)))
    assert(elapsed_ms >= 1000 and elapsed_ms < 2000, string.format(
        "DRAIN-TIMEOUT POSTCONDITION: wait_for_drain must respect the\n" ..
        "  1000 ms budget — return between 1000 and (1000 + slowest\n" ..
        "  write duration) ms. Got elapsed=%.0f ms.", elapsed_ms))
    assert(w:pending_count() >= 1, string.format(
        "DRAIN-TIMEOUT POSTCONDITION: pending_count must be > 0 after\n" ..
        "  timeout (some writes did not get to run). Got %d.",
        w:pending_count()))
    print(string.format(
        "  ✓ drain timeout: returned false after %.0f ms with %d pending",
        elapsed_ms, w:pending_count()))
end

-- ----------------------------------------------------------------------
-- Production-contract precondition: media_status (the real worker
-- module) must expose the contract surface. This is the half that's
-- red today — T024 lands wait_for_drain + pending_count on
-- media_status.
-- ----------------------------------------------------------------------

assert(type(media_status.cancel_background_probe) == "function", string.format(
    "PRODUCTION SURFACE: media_status.cancel_background_probe must exist.\n" ..
    "  Got type: %s", type(media_status.cancel_background_probe)))

assert(type(media_status.wait_for_drain) == "function", string.format(
    "PRODUCTION SURFACE: media_status.wait_for_drain must exist (T024).\n" ..
    "  Got type: %s. The pre-switch handler can't enforce the 1000 ms\n" ..
    "  drain budget without it.", type(media_status.wait_for_drain)))

assert(type(media_status.pending_count) == "function", string.format(
    "PRODUCTION SURFACE: media_status.pending_count must exist (T024).\n" ..
    "  Got type: %s. The drain-timeout warning needs it for the\n" ..
    "  diagnostic log line.", type(media_status.pending_count)))

print("  ✓ production surface present on media_status")

-- ----------------------------------------------------------------------
-- The third contract scenario from contracts/worker_cancel_drain.md —
-- "stale-write safety net" (drain times out, the over-budget write
-- fires AFTER the switch, write callback consults
-- assert_project_id_is_live and no-ops) — is verified end-to-end by:
--   * test_assert_project_id_is_live.lua (T006) — Layer 2 helper's
--     return / log behavior for stale ids.
--   * test_anamnesis_reimport_no_asserts.lua (T009) — full integration
--     under a real re-import scenario with media_status's worker.
-- This file scope-bounds itself to the cancel-and-drain primitives.
-- ----------------------------------------------------------------------

print("✅ test_worker_cancel_drain passed")
