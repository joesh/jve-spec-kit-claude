-- Contract test (014, T004): project_will_change ordering vs database swap.
--
-- Spec ref: contracts/signal_will_change.md, FR-001, FR-002, FR-004.
--
-- Domain: when the active project is swapped (open / import / new / close),
-- handlers split into two phases:
--   * pre-switch: outgoing project's DB is still the live connection.
--     Modules with pending writes flush here.
--   * post-switch: incoming project's DB is the live connection.
--     Modules clear caches and load the new project's persisted state.
--
-- The signal contract is observed via `database.get_current_project_id()` at
-- the moment each handler runs: pre-handlers see the OUTGOING project's id;
-- post-handlers see the INCOMING project's id.
--
-- This test fails today because `project_will_change` is not yet emitted by
-- any production code path. Test will turn green after T016 (signal doc) +
-- T018 (emit point in database.set_path or project_open.lua) land.

require("test_env")

local Signals = require("core.signals")
local database = require("core.database")

print("=== test_project_will_change_ordering ===")

local TEST_DIR = "/tmp/jve/test_014_t004"
os.execute("mkdir -p " .. TEST_DIR)
os.execute("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

local function create_project(label, path)
    database.set_path(path)
    -- Schema is auto-applied by set_path; create a project row so
    -- get_current_project_id returns a stable id.
    local conn = database.get_connection()
    assert(conn, "create_project: no DB connection after set_path")
    -- Use the official Project.create path to keep schema consistent.
    local Project = require("models.project")
    local project = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(project:save(), "create_project: failed to save project " .. label)
    return project.id
end

-- ----------------------------------------------------------------------
-- Set up two real SQLite DBs.
-- ----------------------------------------------------------------------

local p1_path = TEST_DIR .. "/p1.jvp"
local p2_path = TEST_DIR .. "/p2.jvp"
local p1_id = create_project("project_one", p1_path)

-- After this point, the live connection points at p1.
assert(database.get_current_project_id() == p1_id,
    "setup: live DB should be p1 after first create_project")

-- Pre-create p2's DB so the switch can attach it. Switch back to p1
-- afterward so the test starts with p1 as live.
local p2_id = create_project("project_two", p2_path)
database.set_path(p1_path)
assert(database.get_current_project_id() == p1_id,
    "setup: live DB should be p1 again after switching back")

-- ----------------------------------------------------------------------
-- Register handlers that record what they see at handler time.
-- ----------------------------------------------------------------------

Signals.clear_all()

local observations = {
    pre_arg = nil, pre_live = nil, pre_fired = false,
    post_arg = nil, post_live = nil, post_fired = false,
}

Signals.connect("project_will_change", function(outgoing_id)
    observations.pre_fired = true
    observations.pre_arg = outgoing_id
    observations.pre_live = database.get_current_project_id()
end)

Signals.connect("project_changed", function(incoming_id)
    observations.post_fired = true
    observations.post_arg = incoming_id
    observations.post_live = database.get_current_project_id()
end)

-- ----------------------------------------------------------------------
-- Trigger the swap.
--
-- The contract: emitting these two signals around database.set_path is the
-- production code's responsibility. The test invokes the same
-- post_open_init pattern the editor uses, but inlined for clarity.
-- ----------------------------------------------------------------------

-- pre-switch: the live DB MUST still be p1 when this fires.
Signals.emit("project_will_change", p1_id)
assert(observations.pre_fired,
    "pre-switch: project_will_change handler must have fired")
assert(observations.pre_arg == p1_id, string.format(
    "pre-switch arg: expected outgoing=%s, got %s", p1_id, tostring(observations.pre_arg)))
assert(observations.pre_live == p1_id, string.format(
    "pre-switch live invariant: live DB must still be p1 (%s), got %s",
    p1_id, tostring(observations.pre_live)))
print("  ✓ pre-switch handler observed outgoing=p1, live=p1")

-- swap.
database.set_path(p2_path)
assert(database.get_current_project_id() == p2_id,
    "swap: live DB should be p2 after set_path")

-- post-switch: the live DB MUST now be p2.
Signals.emit("project_changed", p2_id)
assert(observations.post_fired,
    "post-switch: project_changed handler must have fired")
assert(observations.post_arg == p2_id, string.format(
    "post-switch arg: expected incoming=%s, got %s", p2_id, tostring(observations.post_arg)))
assert(observations.post_live == p2_id, string.format(
    "post-switch live invariant: live DB must be p2 (%s), got %s",
    p2_id, tostring(observations.post_live)))
print("  ✓ post-switch handler observed incoming=p2, live=p2")

-- ----------------------------------------------------------------------
-- The above passes once the SIGNALS work. The deeper contract test —
-- that production code (database.set_path / project_open) automatically
-- emits project_will_change in the right place — is verified by checking
-- that a *second* handler registration sees the signal during the
-- production swap path (not just our manual emit).
--
-- This branch FAILS today: production set_path does not emit
-- project_will_change. After T018 lands, this branch will pass.
-- ----------------------------------------------------------------------

Signals.clear_all()
local prod_observations = { pre_fired = false, pre_arg = nil, pre_live = nil }
Signals.connect("project_will_change", function(outgoing_id)
    prod_observations.pre_fired = true
    prod_observations.pre_arg = outgoing_id
    prod_observations.pre_live = database.get_current_project_id()
end)

-- Trigger a real production swap: set_path should fire project_will_change
-- BEFORE closing the outgoing connection.
database.set_path(p1_path)

assert(prod_observations.pre_fired,
    "PRODUCTION CONTRACT: database.set_path must emit project_will_change\n" ..
    "  before closing the outgoing connection. Today it does not — this test\n" ..
    "  fails until T018 lands an emit at the top of set_path.")
assert(prod_observations.pre_arg == p2_id, string.format(
    "PRODUCTION CONTRACT: emitted outgoing should be p2 (the active id at\n" ..
    "  emit time). Got %s.", tostring(prod_observations.pre_arg)))
assert(prod_observations.pre_live == p2_id, string.format(
    "PRODUCTION CONTRACT: live DB at emit time must be p2 (the OUTGOING\n" ..
    "  project — set_path has not yet swapped). Got %s.",
    tostring(prod_observations.pre_live)))
print("  ✓ production swap emits project_will_change with outgoing=p2, live=p2")

-- ----------------------------------------------------------------------
-- Cleanup.
-- ----------------------------------------------------------------------

Signals.clear_all()
os.execute("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp*")

print("✅ test_project_will_change_ordering passed")
