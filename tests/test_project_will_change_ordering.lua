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

require("test_env")

local Signals = require("core.signals")
local database = require("core.database")
local Project = require("models.project")

print("=== test_project_will_change_ordering ===")

local TEST_DIR = "/tmp/jve/test_014_t004"

local function reset_test_dir()
    os.execute("mkdir -p " .. TEST_DIR)
    os.execute("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")
end

local function create_project_at(label, path)
    database.set_path(path)
    local project = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(project:save(), "create_project_at: failed to save " .. label)
    return project.id
end

local function record_handler(observation_table, key)
    return function(project_id_arg)
        observation_table.fired = true
        observation_table[key] = project_id_arg
        observation_table.live = database.get_current_project_id()
    end
end

-- ----------------------------------------------------------------------
-- Setup: two real SQLite DBs, current = p1.
-- ----------------------------------------------------------------------

reset_test_dir()
local p1_id = create_project_at("project_one", TEST_DIR .. "/p1.jvp")
local p2_id = create_project_at("project_two", TEST_DIR .. "/p2.jvp")
database.set_path(TEST_DIR .. "/p1.jvp")
assert(database.get_current_project_id() == p1_id,
    "setup: live DB should be p1 after switching back")

-- ----------------------------------------------------------------------
-- Register handlers; trigger a swap p1 → p2 by calling set_path.
-- ----------------------------------------------------------------------

Signals.clear_all()
local pre = { fired = false }
local post = { fired = false }
Signals.connect("project_will_change", record_handler(pre, "outgoing"))
Signals.connect("project_changed", record_handler(post, "incoming"))

database.set_path(TEST_DIR .. "/p2.jvp")
-- Production set_path is responsible for emitting project_will_change
-- BEFORE the close. Production callers (open_project, importers) emit
-- project_changed AFTER post-open wiring. The post-switch handler in
-- this test fires manually because we're observing the swap primitive
-- in isolation, not the full open flow.
Signals.emit("project_changed", p2_id)

-- ----------------------------------------------------------------------
-- Assertions.
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
os.execute("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

print("✅ test_project_will_change_ordering passed")
