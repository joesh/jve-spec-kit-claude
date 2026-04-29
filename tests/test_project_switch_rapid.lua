-- Edge-case test (014, T013): rapid sequential project switches.
--
-- Spec ref: spec.md edge case #5, FR-001, FR-003.
--
-- Domain: P1 → P2 → P3 within a single Qt event-loop turn. Each
-- switch is its own complete two-phase cycle. Pending state from P1
-- must NOT leak into P2's or P3's DB. The pre-switch signal must
-- fire exactly once per outgoing project.
--
-- This stresses the live-DB invariant: if the contract held only
-- "approximately", a fast-fired sequence could route a P1 write to
-- P3's DB. The contract requires per-switch isolation.
--
-- Red today: project_will_change is not emitted at all. After T018,
-- the test pins per-switch outgoing emission.
--
-- NSF: verifies the pre-switch signal fires once per switch with the
-- correct outgoing id, in the correct order. Also verifies the live
-- DB at each pre-handler invocation matches the expected outgoing.

require("test_env")

local Signals = require("core.signals")
local database = require("core.database")
local Project = require("models.project")

print("=== test_project_switch_rapid ===")

local TEST_DIR = "/tmp/jve/test_014_t013"

local function shell(cmd)
    local ok = os.execute(cmd)
    if ok ~= 0 and ok ~= true then
        error(string.format("shell('%s') failed: ok=%s", cmd, tostring(ok)))
    end
end

-- ----------------------------------------------------------------------
-- Setup: three real DBs.
-- ----------------------------------------------------------------------

shell("mkdir -p " .. TEST_DIR)
shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp* " ..
      TEST_DIR .. "/p3.jvp*")

local function attach_with_project(label, path)
    assert(database.set_path(path), "attach: set_path failed for " .. path)
    local p = Project.create(label, { fps_mismatch_policy = "resample" })
    assert(p and p:save() and type(p.id) == "string",
        "attach: project create/save postcondition for " .. label)
    return p.id
end

local p1_id = attach_with_project("p1", TEST_DIR .. "/p1.jvp")
local p2_id = attach_with_project("p2", TEST_DIR .. "/p2.jvp")
local p3_id = attach_with_project("p3", TEST_DIR .. "/p3.jvp")
assert(database.set_path(TEST_DIR .. "/p1.jvp"), "setup: switch to p1")
assert(database.get_current_project_id() == p1_id, "setup: live = p1")

-- ----------------------------------------------------------------------
-- Record every pre-switch fire with the live DB at handler time.
-- ----------------------------------------------------------------------

Signals.clear_all()
local fires = {}  -- ordered list of {outgoing, live_at_fire}
Signals.connect("project_will_change", function(outgoing)
    fires[#fires + 1] = {
        outgoing = outgoing,
        live = database.get_current_project_id(),
    }
end)

-- ----------------------------------------------------------------------
-- Rapid switches: P1 → P2 → P3.
-- ----------------------------------------------------------------------

assert(database.set_path(TEST_DIR .. "/p2.jvp"), "swap1: p1 → p2")
assert(database.set_path(TEST_DIR .. "/p3.jvp"), "swap2: p2 → p3")

-- ----------------------------------------------------------------------
-- Assertions: exactly two pre-switch fires, in order, each with the
-- correct outgoing id and matching live-DB observation.
-- ----------------------------------------------------------------------

assert(#fires == 2, string.format(
    "RAPID SWITCH CONTRACT: project_will_change must fire exactly\n" ..
    "  once per outgoing project. Two switches (p1→p2, p2→p3) → 2\n" ..
    "  fires expected. Got #fires=%d. Did set_path emit the signal\n" ..
    "  at all (T018)?", #fires))

assert(fires[1].outgoing == p1_id, string.format(
    "RAPID FIRE 1: outgoing must be p1=%s for the first switch.\n" ..
    "  Got %s.", p1_id, tostring(fires[1].outgoing)))
assert(fires[1].live == p1_id, string.format(
    "RAPID FIRE 1 LIVE INVARIANT: at handler time, live DB must be p1=%s\n" ..
    "  (the OUTGOING — set_path emits BEFORE the close). Got %s.",
    p1_id, tostring(fires[1].live)))

assert(fires[2].outgoing == p2_id, string.format(
    "RAPID FIRE 2: outgoing must be p2=%s for the second switch.\n" ..
    "  Got %s.", p2_id, tostring(fires[2].outgoing)))
assert(fires[2].live == p2_id, string.format(
    "RAPID FIRE 2 LIVE INVARIANT: at handler time, live DB must be p2=%s\n" ..
    "  (the OUTGOING for the p2→p3 switch). Got %s.",
    p2_id, tostring(fires[2].live)))
print(string.format("  ✓ 2 fires: p1→p2 and p2→p3, each with correct outgoing"))

-- Final state: live = p3.
assert(database.get_current_project_id() == p3_id, string.format(
    "POSTCONDITION: after both switches, live DB must be p3=%s. Got %s.",
    p3_id, tostring(database.get_current_project_id())))
print("  ✓ final live DB = p3")

Signals.clear_all()
shell("rm -f " .. TEST_DIR .. "/p1.jvp* " .. TEST_DIR .. "/p2.jvp* " ..
      TEST_DIR .. "/p3.jvp*")

print("✅ test_project_switch_rapid passed")
