-- T048 — helper stamp_identity_marker contract
--           (spec 023, contracts/helper-protocol.md
--                  §stamp_identity_marker).
--
-- State-changing verb that mutates Resolve's project state by adding
-- a marker with `customData == clip.id` (the JVE identity carrier per
-- the marker convention — same channel §read_identities reads back).
--
-- Contract:
--   args:   { resolve_item_id, custom_data, change_token }
--   result: { stamped: bool }  — true when AddMarker was called;
--                                false when item already had it
--                                (idempotent no-op).
--   Idempotent on (change_token, (resolve_item_id, custom_data)).
--
-- Contract-test scope (mirrors T014 import_timeline / T038 render):
-- asserts wire gates the helper enforces WITHOUT actually stamping
-- (which would mutate Joe's open Resolve project). Happy-path stamp +
-- the conflict-on-different-customData path are exercised by T050
-- live test.
--
-- Run via `jve --test`.

local fixture  = require("synthetic.binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-stamp.sock")

local VALID_TOKEN = {
    project_id = "p-test",
    sequence_id = "s-test",
    mutation_generation = 1,
}

-- ─── missing resolve_item_id → bad_request ─────────────────────────
do
    local r = fixture.request(fix, "stamp_identity_marker", {
        custom_data  = "some-clip-uuid",
        change_token = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request",
        "missing resolve_item_id")
    assert(r.error.message:find("resolve_item_id", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing resolve_item_id → bad_request")
end

-- ─── missing custom_data → bad_request ─────────────────────────────
do
    local r = fixture.request(fix, "stamp_identity_marker", {
        resolve_item_id = "1003",
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "missing custom_data")
    assert(r.error.message:find("custom_data", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing custom_data → bad_request")
end

-- ─── empty resolve_item_id → bad_request ───────────────────────────
do
    local r = fixture.request(fix, "stamp_identity_marker", {
        resolve_item_id = "",
        custom_data     = "x",
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request",
        "empty resolve_item_id")
    print("  ✓ empty resolve_item_id → bad_request")
end

-- ─── empty custom_data → bad_request ───────────────────────────────
do
    local r = fixture.request(fix, "stamp_identity_marker", {
        resolve_item_id = "1003",
        custom_data     = "",
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request", "empty custom_data")
    print("  ✓ empty custom_data → bad_request")
end

-- ─── non-string types → bad_request ────────────────────────────────
do
    local r = fixture.request(fix, "stamp_identity_marker", {
        resolve_item_id = 1003,           -- number, not string
        custom_data     = "ok-clip-uuid",
        change_token    = VALID_TOKEN,
    })
    fixture.assert_structured_error(r, "bad_request",
        "resolve_item_id non-string")
    print("  ✓ resolve_item_id non-string → bad_request")
end

-- ─── missing change_token gates on JVE side (FR-008) ───────────────
do
    local ok, err = pcall(protocol.idempotency_key, {
        verb = "stamp_identity_marker",
        args = { resolve_item_id = "1003", custom_data = "x" },
    })
    assert(not ok, "missing change_token must raise on the client side")
    assert(tostring(err):find("change_token", 1, true),
        "error should name change_token: " .. tostring(err))
    print("  ✓ missing change_token → client-side assertion (FR-008)")
end

fixture.stop(fix)

print("✅ test_helper_stamp_identity_marker.lua passed")
