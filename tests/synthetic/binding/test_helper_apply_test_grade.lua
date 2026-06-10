-- T034 prerequisite — helper apply_test_grade contract
--           (spec 023, contracts/helper-protocol.md §apply_test_grade).
--
-- Test-only state-changing verb that puts a KNOWN grade on a fixture
-- timeline item via Resolve's documented write surfaces (SetCDL /
-- SetLUT) — the scripting equivalent of the operator grading the clip
-- in Resolve's UI. Drives the T034 fidelity-downgrade and T033
-- pixel-compare live tests.
--
-- Contract-test scope (mirrors §stamp_identity_marker's test): asserts
-- the wire gates the helper enforces WITHOUT applying anything (which
-- would mutate the open Resolve project — forbidden here per
-- feedback_contract_tests_must_not_poke_live_resolve). Happy paths are
-- exercised by the T034 live test against the VM.
--
-- Run via `jve --test`.

local fixture  = require("synthetic.binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-apply-grade.sock")

local VALID_TOKEN = {
    project_id = "p-test",
    sequence_id = "s-test",
    mutation_generation = 1,
}
local VALID_CDL = {
    slope  = { 1.2, 0.9, 0.85 },
    offset = { 0.02, -0.01, 0.03 },
    power  = { 0.95, 1.1, 1.05 },
    sat    = 0.8,
}

-- ─── missing resolve_item_id → bad_request ─────────────────────────
do
    local r = fixture.request(fix, "apply_test_grade", {
        cdl          = VALID_CDL,
        change_token = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request",
        "missing resolve_item_id")
    assert(r.error.message:find("resolve_item_id", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing resolve_item_id → bad_request")
end

-- ─── neither cdl nor lut_path → bad_request ────────────────────────
do
    local r = fixture.request(fix, "apply_test_grade", {
        resolve_item_id = "1003",
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request",
        "neither cdl nor lut_path")
    assert(r.error.message:find("cdl", 1, true)
        and r.error.message:find("lut_path", 1, true),
        "bad_request should name both options: " .. r.error.message)
    print("  ✓ neither cdl nor lut_path → bad_request")
end

-- ─── malformed cdl triple → bad_request ────────────────────────────
do
    local r = fixture.request(fix, "apply_test_grade", {
        resolve_item_id = "1003",
        cdl = {
            slope  = { 1.0, 1.0 },          -- arity 2, not 3
            offset = { 0, 0, 0 },
            power  = { 1, 1, 1 },
            sat    = 1.0,
        },
        change_token = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "bad slope arity")
    assert(r.error.message:find("slope", 1, true),
        "bad_request should name the bad key: " .. r.error.message)
    print("  ✓ malformed cdl triple → bad_request")
end

-- ─── unknown cdl key → bad_request ─────────────────────────────────
do
    local cdl = {
        slope = { 1, 1, 1 }, offset = { 0, 0, 0 },
        power = { 1, 1, 1 }, sat = 1.0, gamma = 2.2,
    }
    local r = fixture.request(fix, "apply_test_grade", {
        resolve_item_id = "1003",
        cdl             = cdl,
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "unknown cdl key")
    assert(r.error.message:find("gamma", 1, true),
        "bad_request should name the unknown key: " .. r.error.message)
    print("  ✓ unknown cdl key → bad_request")
end

-- ─── relative lut_path → bad_request ───────────────────────────────
do
    local r = fixture.request(fix, "apply_test_grade", {
        resolve_item_id = "1003",
        lut_path        = "k2383.cube",
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "relative lut_path")
    assert(r.error.message:find("absolute", 1, true),
        "bad_request should demand absolute path: " .. r.error.message)
    print("  ✓ relative lut_path → bad_request")
end

-- ─── unknown args field → bad_request ──────────────────────────────
do
    local r = fixture.request(fix, "apply_test_grade", {
        resolve_item_id = "1003",
        cdl             = VALID_CDL,
        drx             = "/tmp/look.drx",
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "unknown args field")
    assert(r.error.message:find("drx", 1, true),
        "bad_request should name the unknown field: " .. r.error.message)
    print("  ✓ unknown args field → bad_request")
end

-- ─── missing change_token gates on JVE side (FR-008) ───────────────
do
    local ok, err = pcall(protocol.idempotency_key, {
        verb = "apply_test_grade",
        args = { resolve_item_id = "1003", cdl = VALID_CDL },
    })
    assert(not ok, "missing change_token must raise on the client side")
    assert(tostring(err):find("change_token", 1, true),
        "error should name change_token: " .. tostring(err))
    print("  ✓ missing change_token → client-side assertion (FR-008)")
end

fixture.stop(fix)

print("✅ test_helper_apply_test_grade.lua passed")
