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
--   State-changing + idempotent on (change_token + spec hash) per
--   helper-protocol.md.
--
-- render_status contract:
--   args:   { job_id }
--   result: { state ∈ {queued, rendering, completed, failed},
--             progress ∈ [0, 100],
--             output_paths? (array of absolute paths, present only
--                            when state = "completed") }
--   Pollable. Render failure is reported via state="failed", NOT via a
--   protocol error envelope.
--
-- This is the RED test that drives T039. The helper-side
-- implementation must:
--   1. Validate args at the wire boundary (bad_request for missing /
--      malformed spec, missing change_token, missing job_id).
--   2. Honour idempotency: same (change_token, spec) → same job_id.
--   3. Return the documented per-job state enum + progress shape;
--      output_paths gated strictly on state == "completed".
--
-- Until T039 lands the verbs are wired to `_unimplemented` (return
-- `not_implemented`), so every assertion below is RED. Idempotency
-- exercise (sending the same request twice) is deferred to live tests
-- (T041) because the contract test runs against a fixture helper that
-- does not actually render — but the bad_request gates and the
-- response-shape assertions are wire-only and ship here.
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

local RENDER_STATES = {
    queued    = true,
    rendering = true,
    completed = true,
    failed    = true,
}

-- ─── queue_render: happy-path result shape ─────────────────────────
do
    local r = fixture.request(fix, "queue_render", {
        spec         = VALID_SPEC,
        change_token = VALID_TOKEN,
    })
    assert(r.ok == true, string.format(
        "queue_render: expected ok=true, got %s/%s",
        r.error and r.error.code, r.error and r.error.message))
    assert(type(r.result) == "table",
        "queue_render: result must be a JSON object")
    assert(type(r.result.job_id) == "string" and r.result.job_id ~= "",
        "queue_render: result.job_id must be non-empty string")
    print(string.format("  ✓ queue_render → job_id=%q", r.result.job_id))
end

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

-- ─── queue_render: missing change_token gates on client side ─────
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

-- ─── queue_render: malformed spec missing preset_name ──────────────
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

-- ─── queue_render: malformed spec missing target_dir ───────────────
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

-- ─── render_status: happy-path result shape ────────────────────────
do
    local r = fixture.request(fix, "render_status", {
        job_id = "test-job-1",
    })
    assert(r.ok == true, string.format(
        "render_status: expected ok=true, got %s/%s",
        r.error and r.error.code, r.error and r.error.message))
    assert(type(r.result) == "table",
        "render_status: result must be a JSON object")
    assert(type(r.result.state) == "string"
        and RENDER_STATES[r.result.state], string.format(
        "render_status: state %q not in closed set "
        .. "{queued, rendering, completed, failed}",
        tostring(r.result.state)))
    assert(type(r.result.progress) == "number"
        and r.result.progress >= 0 and r.result.progress <= 100,
        string.format("render_status: progress must be number in "
            .. "[0,100], got %s", tostring(r.result.progress)))
    -- output_paths gating: present only when state==completed; when
    -- present, must be non-empty array of non-empty absolute paths.
    if r.result.state == "completed" then
        assert(type(r.result.output_paths) == "table",
            "render_status: state=completed requires output_paths array")
        assert(#r.result.output_paths > 0,
            "render_status: state=completed must have ≥1 output_paths")
        for i, p in ipairs(r.result.output_paths) do
            assert(type(p) == "string" and p ~= "" and p:sub(1, 1) == "/",
                string.format("output_paths[%d] must be non-empty "
                    .. "absolute path, got %q", i, tostring(p)))
        end
    else
        assert(r.result.output_paths == nil, string.format(
            "render_status: output_paths must be absent when "
            .. "state=%q (only present when completed)",
            r.result.state))
    end
    print(string.format("  ✓ render_status → state=%q progress=%s",
        r.result.state, tostring(r.result.progress)))
end

-- ─── render_status: missing job_id → bad_request ───────────────────
do
    local r = fixture.request(fix, "render_status", {})
    assert_structured_error(r, "bad_request", "missing job_id")
    assert(r.error.message:find("job_id", 1, true),
        "bad_request should name the missing arg: " .. r.error.message)
    print("  ✓ missing job_id → bad_request")
end

-- ─── render_status: malformed job_id type → bad_request ────────────
do
    local r = fixture.request(fix, "render_status", { job_id = 42 })
    assert_structured_error(r, "bad_request", "job_id wrong type")
    assert(r.error.message:find("job_id", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ job_id non-string → bad_request")
end

fixture.stop(fix)

print("✅ test_helper_render.lua passed")
