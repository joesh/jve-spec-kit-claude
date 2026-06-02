-- T038 — helper queue_render + render_status contract
--           (spec 023, contracts/helper-protocol.md §queue_render
--                  + §render_status).
--
-- queue_render queues a Resolve render of the graded timeline and is
-- the bridge's full-fidelity path (FR-018): node graphs that exceed
-- CDL/LUT (fidelity = partial/unrepresentable) are realized via the
-- render and JVE relinks to `output_paths` (FR-019).
--
-- queue_render contract:
--   args:   { spec: {preset_name, target_dir, file_prefix?}, change_token }
--   result: { job_id: string }
--   State-changing + idempotent on (change_token + spec hash).
--
-- render_status contract:
--   args:   { job_id }
--   result: { state ∈ {queued, rendering, completed, failed},
--             progress ∈ [0, 100],
--             output_paths? (array of absolute paths, present only
--                            when state == "completed") }
--   Pollable. Render failure is reported via state="failed", NOT via a
--   protocol error envelope.
--
-- Contract-test scope (mirrors T014 import_timeline): asserts the wire
-- gates the helper enforces WITHOUT touching the live Resolve API —
-- bad_request paths for malformed envelopes/args and closed-set error
-- code discipline. Happy-path result-shape assertions belong to the
-- live test (T041) because a real queue_render mutates Joe's Resolve
-- render queue and we shouldn't pollute that from a contract test.
--
-- Until T039 lands the verbs are wired to `_unimplemented` (return
-- `not_implemented`), so every assertion below is RED.
--
-- Run via `jve --test`.

local fixture  = require("binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-render.sock")

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
local VALID_SPEC = {
    preset_name = "JVE Bridge Default",
    target_dir  = "/tmp/jve-render-out",
}

-- ─── queue_render: missing spec → bad_request ───────────────────────
do
    local r = fixture.request(fix, "queue_render", {
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request", "missing spec")
    assert(r.error.message:find("spec", 1, true),
        "bad_request message should name the missing arg: "
        .. r.error.message)
    print("  ✓ missing spec → bad_request")
end

-- ─── queue_render: missing change_token gates on JVE side ──────────
-- protocol.idempotency_key asserts before the request can be built —
-- state-changing verbs MUST carry a change_token (FR-008).
do
    local ok, err = pcall(protocol.idempotency_key, {
        verb = "queue_render",
        args = { spec = VALID_SPEC },  -- no change_token
    })
    assert(not ok, "missing change_token must raise on the client side")
    assert(tostring(err):find("change_token", 1, true),
        "error should name change_token: " .. tostring(err))
    print("  ✓ missing change_token → client-side assertion (FR-008)")
end

-- ─── queue_render: spec missing preset_name → bad_request ──────────
do
    local r = fixture.request(fix, "queue_render", {
        spec         = { target_dir = "/tmp/r" },  -- preset_name missing
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request",
        "spec missing preset_name")
    assert(r.error.message:find("preset_name", 1, true),
        "bad_request should name the missing spec field: "
        .. r.error.message)
    print("  ✓ spec without preset_name → bad_request")
end

-- ─── queue_render: spec missing target_dir → bad_request ───────────
do
    local r = fixture.request(fix, "queue_render", {
        spec         = { preset_name = "X" },  -- target_dir missing
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request",
        "spec missing target_dir")
    assert(r.error.message:find("target_dir", 1, true),
        "bad_request should name the missing spec field: "
        .. r.error.message)
    print("  ✓ spec without target_dir → bad_request")
end

-- ─── queue_render: spec wrong type → bad_request ───────────────────
do
    local r = fixture.request(fix, "queue_render", {
        spec         = "not-an-object",
        change_token = VALID_TOKEN,
    })
    assert_structured_error(r, "bad_request", "spec wrong type")
    print("  ✓ spec non-object → bad_request")
end

-- ─── render_status: missing job_id → bad_request ───────────────────
do
    local r = fixture.request(fix, "render_status", {})
    assert_structured_error(r, "bad_request", "missing job_id")
    assert(r.error.message:find("job_id", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing job_id → bad_request")
end

-- ─── render_status: non-string job_id → bad_request ────────────────
do
    local r = fixture.request(fix, "render_status", { job_id = 42 })
    assert_structured_error(r, "bad_request", "job_id wrong type")
    assert(r.error.message:find("job_id", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ job_id non-string → bad_request")
end

-- ─── render_status: empty-string job_id → bad_request ──────────────
do
    local r = fixture.request(fix, "render_status", { job_id = "" })
    assert_structured_error(r, "bad_request", "job_id empty string")
    print("  ✓ job_id empty string → bad_request")
end

fixture.stop(fix)

print("✅ test_helper_render.lua passed")
