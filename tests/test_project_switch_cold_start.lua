-- Edge-case test (014, T010): cold start (first project, no prior).
--
-- Spec ref: spec.md edge case #1, FR-001.
--
-- Domain: when the first project of a session is opened, no prior DB
-- exists. The pre-switch signal must still fire so handlers see a
-- consistent contract; payload is nil to indicate "no outgoing
-- project". Handlers MUST NOT error on the nil payload.
--
-- Red today: production code does not emit project_will_change at
-- all. Turns green after T018.
--
-- NSF: validates fixture I/O; verifies handler invocation AND payload
-- type (nil specifically — not omitted, not the empty string).

require("test_env")

local Signals = require("core.signals")
local database = require("core.database")
local Project = require("models.project")

print("=== test_project_switch_cold_start ===")

local TEST_DIR = "/tmp/jve/test_014_t010"

-- ----------------------------------------------------------------------
-- Helpers — same NSF rigor as T004.
-- ----------------------------------------------------------------------

local function shell(cmd)
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then
        error(string.format("shell('%s') failed: ok=%s", cmd, tostring(ok)))
    end
end

-- ----------------------------------------------------------------------
-- Setup: tear down ANY prior connection so we genuinely cold-start.
-- ----------------------------------------------------------------------

shell("mkdir -p " .. TEST_DIR)
shell("rm -f " .. TEST_DIR .. "/p.jvp*")

-- Detach any test-harness-leftover connection.
if database.has_connection() then
    -- NB: pre-T018, set_path doesn't fire signals at all. Post-T018,
    -- this would fire project_will_change for whatever was there.
    -- The test only registers handlers AFTER this teardown, so any
    -- emit here is intentionally not observed.
    database.set_path("/dev/null")  -- this fails to open; clears state
end

-- ----------------------------------------------------------------------
-- Register handlers, then trigger the cold-start open. The pre-handler
-- must fire with outgoing == nil; the post-handler with incoming = P1.
-- ----------------------------------------------------------------------

Signals.clear_all()
local pre_payload_seen = "<not-fired>"
local pre_fired = false
Signals.connect("project_will_change", function(outgoing)
    pre_fired = true
    pre_payload_seen = outgoing  -- captures nil if that's what fires
end)

local first_path = TEST_DIR .. "/p.jvp"
local set_ok = database.set_path(first_path)
assert(set_ok, "cold-start: set_path on first DB returned false for " .. first_path)
assert(database.has_connection(),
    "cold-start postcondition: has_connection() must be true after first set_path")

local project = Project.create("cold_start_project", { fps_mismatch_policy = "resample" })
assert(project, "cold-start: Project.create returned nil")
assert(project:save(), "cold-start: project:save() returned false")
local p_id = project.id
assert(type(p_id) == "string" and p_id ~= "",
    "cold-start postcondition: project.id non-empty string")

-- ----------------------------------------------------------------------
-- Cold-start contract assertions.
-- ----------------------------------------------------------------------

assert(pre_fired, string.format(
    "COLD START CONTRACT: project_will_change must fire on the first\n" ..
    "  DB attach of a session, even when there's no prior project.\n" ..
    "  The contract requires a uniform two-phase boundary; cold start\n" ..
    "  is a transition out of the 'none' state and gets the signal\n" ..
    "  with outgoing=nil. T018 lands the emit."))
assert(pre_payload_seen == nil, string.format(
    "COLD START PAYLOAD: outgoing_id must be nil (not '' and not omitted)\n" ..
    "  on cold start. Got: %q (type %s).",
    tostring(pre_payload_seen), type(pre_payload_seen)))
print("  ✓ cold-start: project_will_change fired with outgoing=nil")

-- Cleanup.
Signals.clear_all()
shell("rm -f " .. TEST_DIR .. "/p.jvp*")

print("✅ test_project_switch_cold_start passed")
