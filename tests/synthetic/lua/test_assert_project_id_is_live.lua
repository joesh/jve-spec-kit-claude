-- Contract test (014, T006): Layer 2 assert_project_id_is_live no-op-on-stale.
--
-- Spec ref: contracts/persist_now_validation.md, FR-006.
--
-- Domain: modules that cache `current_project_id` at the module level
-- need a defensive check before any DB write — the cache may have gone
-- stale during a project switch (deferred work fires after the switch).
-- The check is `database.assert_project_id_is_live(cached_id, label)`:
--
--   * Returns true when cached id matches the live DB.
--   * Returns false (and logs a JVE_ASSERT-style stack trace at error
--     level naming the caller) when the cache is stale. Caller no-ops.
--   * Returns false quietly (no log line) when the cache is empty (nil).
--
-- Distinct from Layer 1 (assert_project_exists hard-asserts on caller
-- bugs). Layer 2 logs-and-returns because deferred work firing post-
-- switch with stale state is an EXPECTED race the contract handles.
--
-- Red today: M.assert_project_id_is_live does not exist on the
-- database module. Turns green after T019 lands the helper.
--
-- NSF: every fixture call validates I/O; each branch (stale / live /
-- empty) has its own dedicated assertion block.

require("test_env")

local database = require("core.database")
local Project = require("models.project")

print("=== test_assert_project_id_is_live ===")

local TEST_DIR = "/tmp/jve/test_014_t006"

-- ----------------------------------------------------------------------
-- Fixture helpers (NSF I/O validation).
-- ----------------------------------------------------------------------

local function shell(cmd)
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then
        error(string.format("shell('%s') failed: ok=%s", cmd, tostring(ok)))
    end
end

local function reset_test_dir()
    shell("mkdir -p " .. TEST_DIR)
    shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")
end

local function attach_db(path)
    local ok = database.set_path(path)
    assert(ok, "attach_db: set_path returned false for " .. path)
    assert(database.has_connection(),
        "attach_db: postcondition — has_connection() must be true")
end

local function create_real_project(label, path)
    attach_db(path)
    local project = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(project, "create_real_project: Project.create returned nil")
    assert(project:save(), "create_real_project: project:save() returned false")
    assert(type(project.id) == "string" and project.id ~= "",
        "create_real_project: postcondition — project.id non-empty string")
    return project.id
end

local function capture_stderr(fn)
    -- Substitute io.stderr with a memory buffer for the duration of fn().
    -- LuaJIT permits direct table assignment to io.stderr; restore the
    -- original after to keep other tests' diagnostics intact.
    -- luacheck: ignore 122 (setting read-only field 'stderr' is intentional here)
    local captured = {}
    local original = io.stderr
    local stub
    stub = setmetatable({}, { __index = function(_, k)
        if k == "write" then
            return function(_, ...)
                for i = 1, select("#", ...) do
                    captured[#captured + 1] = tostring(select(i, ...))
                end
                return stub
            end
        elseif k == "flush" then
            return function() end
        end
    end })
    io.stderr = stub  -- luacheck: ignore 122
    local ok, err = pcall(fn)
    io.stderr = original  -- luacheck: ignore 122
    if not ok then error(err) end
    return table.concat(captured)
end

-- ----------------------------------------------------------------------
-- Setup: real project p1 attached.
-- ----------------------------------------------------------------------

reset_test_dir()
local p1_id = create_real_project("project_one", TEST_DIR .. "/p1.jvp")
local p2_id = create_real_project("project_two", TEST_DIR .. "/p2.jvp")
attach_db(TEST_DIR .. "/p1.jvp")
assert(database.get_current_project_id() == p1_id,
    "setup: live DB should be p1 after switching back")

-- ----------------------------------------------------------------------
-- Precondition: the function must exist on the database module. Asserting
-- this up front turns "function nil" failures into actionable messages
-- instead of cryptic "attempt to call nil value" downstream.
-- ----------------------------------------------------------------------

assert(type(database.assert_project_id_is_live) == "function", string.format(
    "PRECONDITION: database.assert_project_id_is_live must exist as a public\n" ..
    "  function on core.database. T019 lands the helper. Got type: %s",
    type(database.assert_project_id_is_live)))

-- ----------------------------------------------------------------------
-- Branch 1: live path — cached id matches live DB.
--   Expect: returns true; no log line.
-- ----------------------------------------------------------------------

local live_log = capture_stderr(function()
    local result = database.assert_project_id_is_live(p1_id, "test_caller.live_path")
    assert(result == true, string.format(
        "LIVE PATH: cached id matching live DB must return true, got %s",
        tostring(result)))
end)
assert(live_log == "", string.format(
    "LIVE PATH: must NOT emit any log line when cache is live.\n" ..
    "  Captured: %q", live_log))
print("  ✓ live path: returns true, no log line")

-- ----------------------------------------------------------------------
-- Branch 2: stale path — cached id != live DB id.
--   Expect: returns false; log line at error level naming the caller,
--           the cached id, the live id, and a stack trace.
-- ----------------------------------------------------------------------

local stale_log = capture_stderr(function()
    -- Simulate a deferred-work callback whose cache is the OLD project,
    -- but the live DB has switched to a new one.
    local result = database.assert_project_id_is_live(p2_id, "test_caller.stale_path")
    assert(result == false, string.format(
        "STALE PATH: stale cached id must return false, got %s", tostring(result)))
end)
assert(stale_log:find("test_caller.stale_path", 1, true), string.format(
    "STALE PATH LOG: must name the caller_label.\n  Captured: %q", stale_log))
assert(stale_log:find(p2_id, 1, true), string.format(
    "STALE PATH LOG: must include the cached id (%s).\n  Captured: %q",
    p2_id, stale_log))
assert(stale_log:find(p1_id, 1, true), string.format(
    "STALE PATH LOG: must include the live id (%s).\n  Captured: %q",
    p1_id, stale_log))
assert(stale_log:find("ERROR", 1, true), string.format(
    "STALE PATH LOG: must be emitted at error level (broken-invariant\n" ..
    "  tier per CLAUDE.md logger usage). Captured: %q", stale_log))
assert(stale_log:find("stack traceback", 1, true)
    or stale_log:find("traceback", 1, true), string.format(
    "STALE PATH LOG: must include a stack traceback for actionability.\n" ..
    "  Captured: %q", stale_log))
print("  ✓ stale path: returns false, logs error + traceback + caller + ids")

-- ----------------------------------------------------------------------
-- Branch 3: empty-cache path — cached id is nil.
--   Expect: returns false quietly (no log line — nothing to validate).
-- ----------------------------------------------------------------------

local empty_log = capture_stderr(function()
    local result = database.assert_project_id_is_live(nil, "test_caller.empty_path")
    assert(result == false, string.format(
        "EMPTY PATH: nil cached id must return false, got %s", tostring(result)))
end)
assert(empty_log == "", string.format(
    "EMPTY PATH: must NOT emit any log line when cache is empty.\n" ..
    "  Captured: %q", empty_log))
print("  ✓ empty path: returns false, no log line")

-- ----------------------------------------------------------------------
-- Cleanup.
-- ----------------------------------------------------------------------

shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

print("✅ test_assert_project_id_is_live passed")
