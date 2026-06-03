-- T025b cleanup-verb contract — helper `delete_timeline`
--             (spec 023, contracts/helper-protocol.md §delete_timeline).
--
-- State-changing verb that removes a timeline from the open Resolve
-- project. Exists for T025b's end-to-end test teardown; production has
-- no JVE command for it.
--
-- Contract:
--   args:   { resolve_timeline_id, change_token }
--   result: { deleted: bool }  — true when DeleteTimelines succeeded;
--                                false when no matching uid present
--                                (idempotent re-send).
--
-- Contract-test scope: bad-request paths + closed-set discipline
-- WITHOUT actually deleting (which would mutate Joe's open Resolve
-- project, even on the dedicated test project). The happy-path delete
-- is exercised by T025b's e2e live test.
--
-- Run via `jve --test`.

local fixture  = require("binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-delete-timeline.sock")

local function assert_structured_error(parsed, expected_code, label)
    assert(parsed.ok == false, label .. ": expected ok=false")
    assert(type(parsed.error) == "table", label .. ": missing error table")
    assert(type(parsed.error.code) == "string"
        and parsed.error.code ~= "",
        label .. ": error.code must be non-empty string")
    assert(type(parsed.error.message) == "string"
        and parsed.error.message ~= "",
        label .. ": error.message must be non-empty string (never bare)")
    assert(protocol.is_known_error_code(parsed.error.code), string.format(
        "%s: error code %q is not in the closed set",
        label, parsed.error.code))
    assert(parsed.error.code == expected_code, string.format(
        "%s: expected code %q, got %q (%s)",
        label, expected_code, parsed.error.code, parsed.error.message))
end

local VALID_TOKEN = {
    project_id = "p-test",
    sequence_id = "s-test",
    mutation_generation = 1,
}

-- ─── missing resolve_timeline_id → bad_request ──────────────────────
do
    local r = fixture.request(fix, "delete_timeline", {
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request", "missing resolve_timeline_id")
    assert(r.error.message:find("resolve_timeline_id", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing resolve_timeline_id → bad_request")
end

-- ─── empty resolve_timeline_id → bad_request ────────────────────────
do
    local r = fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = "",
        change_token        = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request", "empty resolve_timeline_id")
    print("  ✓ empty resolve_timeline_id → bad_request")
end

-- ─── non-string type → bad_request ──────────────────────────────────
do
    local r = fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = 42,
        change_token        = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request",
        "resolve_timeline_id non-string")
    print("  ✓ resolve_timeline_id non-string → bad_request")
end

-- ─── unknown args field → bad_request ───────────────────────────────
do
    local r = fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = "tl-xxx",
        change_token        = VALID_TOKEN,
        nonsense_field      = true,
    })
    assert_structured_error(r, "bad_request", "unknown args field")
    print("  ✓ unknown args field → bad_request")
end

-- ─── missing change_token gates on JVE side (FR-008) ────────────────
do
    local ok, err = pcall(protocol.idempotency_key, {
        verb = "delete_timeline",
        args = { resolve_timeline_id = "tl-xxx" },
    })
    assert(not ok, "missing change_token must raise on the client side")
    assert(tostring(err):find("change_token", 1, true),
        "error should name change_token: " .. tostring(err))
    print("  ✓ missing change_token → client-side assertion (FR-008)")
end

-- ─── helper-side change_token validation (mirrors stamp/import) ─────
do
    local r = fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = "tl-xxx",
        change_token = { project_id = "p", sequence_id = "s" },  -- no mut_gen
    })
    assert_structured_error(r, "bad_request",
        "change_token missing mutation_generation")
    assert(r.error.message:find("mutation_generation", 1, true),
        "bad_request should name the missing token field: "
        .. r.error.message)
    print("  ✓ change_token missing mutation_generation → bad_request")
end

fixture.stop(fix)

print("✅ test_helper_delete_timeline.lua passed")
