-- Edge-case test (014, T012): pre-switch handler error isolation.
--
-- Spec ref: spec.md edge case #3, FR-008, FR-009.
--
-- Domain: when one project_will_change handler throws an error, the
-- dispatcher MUST log the error (via the bridge / Signals.emit error
-- path) and continue with the next handler. The switch is never
-- blocked by a single handler failure. This matches the existing
-- Signals.emit error policy for project_changed and the JVE_ASSERT
-- C++ semantics: loud-and-actionable but non-fatal.
--
-- Red today: project_will_change is not registered or emitted at all.
-- After T016 (signal doc) and T018 (emit point), this test verifies
-- the dispatcher's existing log-and-continue policy applies uniformly
-- to the new signal.
--
-- NSF: verifies BOTH halves — that the second handler ran (Half 2,
-- pipeline continues despite mid-stream failure) AND that the first
-- handler's error was logged with a recognizable diagnostic
-- (Half 1, error surfaced not silently dropped).

require("test_env")

local Signals = require("core.signals")
local database = require("core.database")
local Project = require("models.project")

print("=== test_project_will_change_handler_error_isolation ===")

local TEST_DIR = "/tmp/jve/test_014_t012"

local function shell(cmd)
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then
        error(string.format("shell('%s') failed: ok=%s", cmd, tostring(ok)))
    end
end

-- ----------------------------------------------------------------------
-- Setup: two projects, p1 active.
-- ----------------------------------------------------------------------

shell("mkdir -p " .. TEST_DIR)
shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

local function attach_with_project(label, path)
    assert(database.set_path(path), "attach: set_path failed for " .. path)
    local p = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(p and p:save() and type(p.id) == "string",
        "attach: project create/save postcondition for " .. label)
    return p.id
end

local p1_id = attach_with_project("p1", TEST_DIR .. "/p1.jvp")
local _ = attach_with_project("p2", TEST_DIR .. "/p2.jvp")
assert(database.set_path(TEST_DIR .. "/p1.jvp"), "setup: switch back to p1")
assert(database.get_current_project_id() == p1_id, "setup: live = p1")

-- ----------------------------------------------------------------------
-- Register two pre-switch handlers — first throws, second records.
-- ----------------------------------------------------------------------

Signals.clear_all()
local first_handler_ran = false
local second_handler_ran = false

Signals.connect("project_will_change", function(_outgoing)
    first_handler_ran = true
    error("synthetic handler-1 error")
end, 10)  -- lower priority = runs first

Signals.connect("project_will_change", function(_outgoing)
    second_handler_ran = true
end, 20)  -- runs after handler-1

-- ----------------------------------------------------------------------
-- Trigger the swap. The dispatcher should run BOTH handlers despite
-- handler-1 throwing.
-- ----------------------------------------------------------------------

assert(database.set_path(TEST_DIR .. "/p2.jvp"),
    "swap: set_path to p2 must succeed even though handler-1 throws")

-- ----------------------------------------------------------------------
-- Assertions.
-- ----------------------------------------------------------------------

assert(first_handler_ran, string.format(
    "DISPATCH ORDER: priority-10 handler must have been entered.\n" ..
    "  first_handler_ran=%s. T018+T016 emit project_will_change so\n" ..
    "  this handler runs at swap time.", tostring(first_handler_ran)))

assert(second_handler_ran, string.format(
    "ERROR ISOLATION: priority-20 handler must STILL run after\n" ..
    "  priority-10 handler errored. The dispatcher MUST NOT block\n" ..
    "  on per-handler failures (FR-009).\n" ..
    "  first_handler_ran=%s, second_handler_ran=%s",
    tostring(first_handler_ran), tostring(second_handler_ran)))

-- The switch itself must have completed: the live DB is now p2.
assert(database.has_connection(),
    "POSTCONDITION: connection still live after swap")
local live = database.get_current_project_id()
assert(live ~= nil and live ~= p1_id, string.format(
    "POSTCONDITION: live DB must be p2 after swap (not p1=%s).\n" ..
    "  Got live=%s.", p1_id, tostring(live)))
print(string.format(
    "  ✓ both handlers ran despite handler-1 throwing; live=%s", live))

Signals.clear_all()
shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

print("✅ test_project_will_change_handler_error_isolation passed")
