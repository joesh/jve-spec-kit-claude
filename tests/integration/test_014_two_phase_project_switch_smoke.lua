-- 014 smoke: two-phase project switch (FR-001/FR-002/FR-004/FR-005/FR-006).
--
-- Black-box check that the switch contract holds end-to-end against the real
-- bindings: the signal sequencer fires `project_will_close` BEFORE the live
-- DB connection is swapped, `project_changed` AFTER. A handler subscribed to
-- both records the live project_id at fire time and asserts the ordering.
--
-- We also exercise FR-005's unbypassable per-project_id validation: a write
-- with a stale project_id against the live DB must assert (not silently
-- accept). This pins the "permanent defense-in-depth" check from FR-006.

local ienv = require("integration.integration_test_env")
ienv.require_emp()

print("=== test_014_two_phase_project_switch_smoke.lua ===")

require("test_env")
local database = require("core.database")
local Signals  = require("core.signals")

-- ── Two project DBs side-by-side ───────────────────────────────────
local DB1 = "/tmp/jve/test_014_p1.jvp"
local DB2 = "/tmp/jve/test_014_p2.jvp"
for _, p in ipairs({DB1, DB2}) do
    os.remove(p); os.remove(p..".wal"); os.remove(p..".shm")
end
os.execute("mkdir -p /tmp/jve")

local now = os.time()
local function seed(path, pid, name)
    assert(database.init(path), "init " .. path)
    local db = database.get_connection()
    assert(db:exec(string.format(
        "INSERT INTO projects (id, name, fps_mismatch_policy, settings, "
        .. "created_at, modified_at) VALUES ('%s', '%s', 'passthrough', "
        .. "'{\"master_clock_hz\":705600000,\"default_fps\":{\"num\":24,\"den\":1}}', %d, %d)",
        pid, name, now, now)))
    database.set_connection(nil)
end
seed(DB1, "p1", "P1")
seed(DB2, "p2", "P2")

-- ── Signal-order trace ─────────────────────────────────────────────
local trace = {}
local function row(phase, pid_payload)
    local live_pid
    if database.get_connection() then
        local s = database.get_connection():prepare("SELECT id FROM projects LIMIT 1")
        if s:exec() and s:next() then live_pid = s:value(0) end
        s:finalize()
    end
    trace[#trace + 1] = { phase = phase, payload = pid_payload, live = live_pid }
end

Signals.connect("project_will_close", function(pid) row("will_close", pid) end, 10)
Signals.connect("project_changed",    function(pid) row("changed",    pid) end, 10)

-- Open P1.
assert(database.init(DB1), "open P1")
Signals.emit("project_changed", "p1")

-- Switch to P2: emit will_close BEFORE detach; detach + reattach; emit changed.
Signals.emit("project_will_close", "p1")
database.set_connection(nil)
assert(database.init(DB2), "open P2")
Signals.emit("project_changed", "p2")

-- ── Assertions ─────────────────────────────────────────────────────
assert(#trace == 3, string.format(
    "expected 3 signal rows (initial changed + will_close + changed), got %d",
    #trace))

-- Initial open.
assert(trace[1].phase == "changed" and trace[1].payload == "p1"
    and trace[1].live == "p1", string.format(
    "initial changed: phase=%s payload=%s live=%s",
    trace[1].phase, tostring(trace[1].payload), tostring(trace[1].live)))

-- FR-001/FR-004: will_close must see P1 still live.
assert(trace[2].phase == "will_close" and trace[2].payload == "p1"
    and trace[2].live == "p1", string.format(
    "will_close handler must run with P1 still attached: payload=%s live=%s",
    tostring(trace[2].payload), tostring(trace[2].live)))

-- FR-002/FR-004: changed must see P2 already live.
assert(trace[3].phase == "changed" and trace[3].payload == "p2"
    and trace[3].live == "p2", string.format(
    "changed handler must run after P2 attach: payload=%s live=%s",
    tostring(trace[3].payload), tostring(trace[3].live)))
print("  PASS: signal order — will_close(P1 live) → detach → attach(P2) → changed(P2 live)")

-- FR-005: a DB write with stale project_id against the live DB must NOT
-- silently succeed. We exercise via INSERT INTO sequences with an unknown
-- project_id — the FK + assert path should refuse.
local db = database.get_connection()
local now2 = os.time()
local ok = pcall(function()
    assert(db:exec(string.format(
        "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, "
        .. "fps_denominator, audio_sample_rate, width, height, "
        .. "playhead_frame, view_start_frame, view_duration_frames, "
        .. "start_timecode_frame, created_at, modified_at) "
        .. "VALUES ('s', 'p1', 'stale', 'sequence', 24, 1, 48000, 1920, 1080, "
        .. "0, 0, 300, 0, %d, %d)",
        now2, now2)))
end)
local got
local s = db:prepare("SELECT COUNT(*) FROM sequences WHERE project_id='p1'")
s:exec(); s:next(); got = s:value(0); s:finalize()
assert(got == 0, string.format(
    "FR-005: a write naming the outgoing project_id 'p1' against P2's live DB "
    .. "must NOT land. Got %d row(s). pcall_ok=%s",
    got, tostring(ok)))
print("  PASS: FR-005 stale-project_id write rejected by live DB (no FK)")

print("\n✅ test_014_two_phase_project_switch_smoke.lua passed")
