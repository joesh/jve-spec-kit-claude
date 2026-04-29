-- Contract test (014, T004): project_will_change ordering vs database swap.
--
-- Spec ref: contracts/signal_will_change.md, FR-001, FR-002, FR-004.
--
-- Domain: when the active project changes (open / import / new / close),
-- handlers split into two phases:
--   * pre-switch: outgoing project's DB is the live connection. Modules
--     with pending writes flush here.
--   * post-switch: incoming project's DB is the live connection. Modules
--     clear caches and load the new project's persisted state.
--
-- The contract is observed via `database.get_current_project_id()` at the
-- moment each handler runs: pre-handlers see the OUTGOING id; post-handlers
-- see the INCOMING id. The DB-swap primitive itself MUST emit the
-- pre-switch signal before closing the outgoing connection.
--
-- Red today: production code does not emit project_will_change. Turns
-- green after T018 lands the emit at the top of database.set_path.
--
-- NSF: every fixture call validates its inputs (Half 1) AND its outputs
-- (Half 2). A failure in test infrastructure surfaces with the offending
-- call's name and arguments, not as a downstream confused assertion.

require("test_env")

local Signals = require("core.signals")
local database = require("core.database")
local Project = require("models.project")
local error_system = require("core.error_system")

print("=== test_project_will_change_ordering ===")

local TEST_DIR = "/tmp/jve/test_014_t004"

-- ----------------------------------------------------------------------
-- Helpers (NSF: both halves — validate inputs, check outputs).
-- ----------------------------------------------------------------------

local function shell(cmd)
    -- os.execute returns ok, "exit", code in 5.2+; in LuaJIT it's a number
    -- (0 = ok). Treat anything non-zero/false as failure with the command
    -- echoed so the test surfaces the bad shell call.
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
    assert(type(path) == "string" and path ~= "",
        "attach_db: path required, got " .. tostring(path))
    local ok = database.set_path(path)
    assert(ok, "attach_db: set_path returned false for " .. path)
    assert(database.has_connection(),
        "attach_db: postcondition — has_connection() must be true after set_path " .. path)
end

local function create_project_at(label, path)
    attach_db(path)
    local project = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(project, "create_project_at: Project.create returned nil for " .. label)
    assert(project:save(),
        "create_project_at: project:save() returned false for " .. label)
    assert(type(project.id) == "string" and project.id ~= "", string.format(
        "create_project_at: postcondition — project.id must be non-empty string, got %s",
        tostring(project.id)))
    return project.id
end

local function require_signal_connect(signal_name, handler)
    local conn = Signals.connect(signal_name, handler)
    if error_system.is_error(conn) then
        error(string.format(
            "Signals.connect('%s', ...) returned error: %s",
            signal_name, tostring(conn.message or conn.code or "unknown")))
    end
    assert(type(conn) == "number", string.format(
        "Signals.connect('%s', ...) postcondition — must return numeric connection id, got %s",
        signal_name, type(conn)))
    return conn
end

local function record_handler(observation_table, payload_key)
    return function(project_id_arg)
        -- Half 2: validate what the contract handed us.
        if project_id_arg ~= nil then
            assert(type(project_id_arg) == "string", string.format(
                "record_handler(%s): contract violation — payload must be string|nil, got %s (%s)",
                payload_key, type(project_id_arg), tostring(project_id_arg)))
        end
        observation_table.fired = true
        observation_table[payload_key] = project_id_arg
        observation_table.live = database.get_current_project_id()
    end
end

-- ----------------------------------------------------------------------
-- Setup: two real SQLite DBs, current = p1.
-- ----------------------------------------------------------------------

reset_test_dir()
local p1_id = create_project_at("project_one", TEST_DIR .. "/p1.jvp")
local p2_id = create_project_at("project_two", TEST_DIR .. "/p2.jvp")
attach_db(TEST_DIR .. "/p1.jvp")
assert(database.get_current_project_id() == p1_id, string.format(
    "setup: live DB should be p1 (%s) after switching back, got %s",
    p1_id, tostring(database.get_current_project_id())))

-- ----------------------------------------------------------------------
-- Register handlers; trigger a swap p1 → p2 by calling set_path.
-- ----------------------------------------------------------------------

Signals.clear_all()
local pre = { fired = false }
local post = { fired = false }
require_signal_connect("project_will_change", record_handler(pre, "outgoing"))
require_signal_connect("project_changed", record_handler(post, "incoming"))

-- Production set_path is responsible for emitting project_will_change
-- BEFORE the close. Production callers (open_project, importers) emit
-- project_changed AFTER post-open wiring. The post-switch handler in
-- this test fires manually because we're observing the swap primitive
-- in isolation, not the full open flow.
attach_db(TEST_DIR .. "/p2.jvp")
Signals.emit("project_changed", p2_id)

-- ----------------------------------------------------------------------
-- Pre-switch contract assertions.
-- ----------------------------------------------------------------------

assert(pre.fired,
    "PRE-SWITCH CONTRACT: database.set_path must emit project_will_change\n" ..
    "  before closing the outgoing connection. T018 lands the emit.")
assert(pre.outgoing == p1_id, string.format(
    "PRE-SWITCH CONTRACT: emitted outgoing must be the active id at\n" ..
    "  emit time (p1=%s). Got %s.", p1_id, tostring(pre.outgoing)))
assert(pre.live == p1_id, string.format(
    "PRE-SWITCH LIVE INVARIANT: at handler time, the live DB must still\n" ..
    "  be the OUTGOING project (p1=%s) — set_path must emit BEFORE the\n" ..
    "  close. Got live=%s.", p1_id, tostring(pre.live)))
print(string.format("  pre-switch: outgoing=%s, live=%s", pre.outgoing, pre.live))

-- ----------------------------------------------------------------------
-- Post-switch contract assertions.
-- ----------------------------------------------------------------------

assert(post.fired, "post-switch handler must have fired (manual emit)")
assert(post.incoming == p2_id, string.format(
    "POST-SWITCH CONTRACT: incoming arg must be p2=%s. Got %s.",
    p2_id, tostring(post.incoming)))
assert(post.live == p2_id, string.format(
    "POST-SWITCH LIVE INVARIANT: at handler time, the live DB must be\n" ..
    "  the INCOMING project (p2=%s). Got live=%s.",
    p2_id, tostring(post.live)))
print(string.format("  post-switch: incoming=%s, live=%s", post.incoming, post.live))

-- ----------------------------------------------------------------------
-- Cleanup.
-- ----------------------------------------------------------------------

Signals.clear_all()
shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

print("✅ test_project_will_change_ordering passed")
