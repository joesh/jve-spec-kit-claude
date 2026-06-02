-- T014 — helper import_timeline contract
--           (spec 023, contracts/helper-protocol.md §import_timeline).
--
-- Asserts every observable surface of the verb that does NOT require a
-- live import:
--   • bad_request paths (missing drt_path, malformed media_roots,
--     nonexistent file) — these reach helper.py without ever touching
--     Resolve and exercise the validation block.
--   • Structured error envelope (closed-set code, non-empty message).
--   • Idempotency-key gate (FR-008): omitting change_token must NOT be
--     silently accepted by the protocol layer.
--
-- The success-shape `{mapping, unrelinked}` is asserted when the verb's
-- relink + identity-mapping land in T029 (mapping/relink against the
-- live scripting surface). We deliberately do NOT poke the live
-- `ImportTimelineFromFile` path here: when Resolve is up, an
-- ill-formed DRT raises a modal "Unable to Import Project" dialog in
-- the user's editor — see todo_t014_extend_import_timeline_success_shape
-- for the deferred assertion that T029 must wire against an
-- authored-by-payload_builder fixture.
--
-- Run via `jve --test`.

local fixture  = require("binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-import.sock")

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

-- ─── bad_request: missing drt_path ──────────────────────────────────────
do
    local r = fixture.request(fix, "import_timeline", {
        media_roots = { "/tmp" },
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request", "missing drt_path")
    assert(r.error.message:find("drt_path", 1, true),
        "bad_request message should name the missing arg: "
        .. r.error.message)
    print("  ✓ missing drt_path → bad_request")
end

-- ─── bad_request: malformed media_roots ─────────────────────────────────
do
    local r = fixture.request(fix, "import_timeline", {
        drt_path = "/tmp/does-not-matter.drt",
        media_roots = "/tmp",  -- string, contract says list[string]
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request", "media_roots wrong type")
    assert(r.error.message:find("media_roots", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ malformed media_roots → bad_request")
end

-- ─── bad_request: drt_path does not exist ───────────────────────────────
do
    local missing = "/tmp/jve-contract-no-such-drt-" .. os.time() .. ".drt"
    os.remove(missing)  -- belt-and-braces in case of collision
    local r = fixture.request(fix, "import_timeline", {
        drt_path = missing,
        media_roots = {},
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request", "drt_path nonexistent")
    assert(r.error.message:find(missing, 1, true)
        or r.error.message:find("does not exist", 1, true),
        "message should explain the path doesn't exist: "
        .. r.error.message)
    print("  ✓ nonexistent drt_path → bad_request")
end

-- ─── idempotency-key gate (protocol-level, FR-008) ──────────────────────
-- Omitting change_token on a state-changing verb must fail on the JVE
-- side (protocol.idempotency_key asserts) — never reach the helper.
-- This is the boundary check that prevents un-idempotent state mutation.
do
    local ok, err = pcall(protocol.idempotency_key, {
        verb = "import_timeline",
        args = {},  -- no change_token
    })
    assert(not ok, "missing change_token must raise on the client side")
    assert(tostring(err):find("change_token", 1, true),
        "error should name change_token: " .. tostring(err))
    print("  ✓ missing change_token → client-side assertion (FR-008)")
end

fixture.stop(fix)

print("✅ test_helper_import_timeline.lua passed")
