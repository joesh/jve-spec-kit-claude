-- test_resolve_bridge_protocol.lua — `core.resolve_bridge.protocol`
-- envelope build/parse contract (T012).
--
-- Per contracts/helper-protocol.md:
--   • Envelope: `{ v, id, verb, args }` request /
--     `{ v, id, ok, result|error }` response, one JSON object per line.
--   • Error is structured `{ code, message }` — never bare string.
--   • `id` is correlation-only; idempotency is keyed on
--     `args.change_token`, NOT `id`. The protocol module exposes the
--     idempotency key as a function so this rule is testable without
--     reading helper-side ledger code.
--   • Closed error-code set; unknown codes parse but the module must
--     surface them as "unknown" so callers don't silently swallow them.

require("test_env")
local protocol = require("core.resolve_bridge.protocol")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end
local function expect_error(label, fn, substr)
    local ok, err = pcall(fn)
    if ok then
        fail = fail + 1; print("FAIL (expected error): " .. label); return
    end
    if substr and not tostring(err):find(substr, 1, true) then
        fail = fail + 1
        print(string.format("FAIL (msg %q lacks %q): %s",
            tostring(err), substr, label))
        return
    end
    pass = pass + 1
end

print("\n=== Resolve Bridge Protocol Tests ===")

-- ─── request build round-trips through parse ─────────────────────────
local change_token = {
    project_id = "p-7",
    sequence_id = "s-3",
    mutation_generation = 42,
}
local req_str = protocol.build_request({
    id   = "corr-1",
    verb = "import_timeline",
    args = {
        drt_path     = "/tmp/jve/out.drt",
        media_roots  = { "/Volumes/Media" },
        change_token = change_token,
    },
})
-- Wire format is one JSON object per line, `\n`-terminated. The JSON body
-- itself has no embedded newlines; the terminator is the only `\n`.
check("request body has no embedded newlines",
    not req_str:sub(1, -2):find("\n"))
check("request ends with newline terminator", req_str:sub(-1) == "\n")

local parsed_req = protocol.parse_request(req_str)
check("parsed v == 1",                parsed_req.v == 1)
check("parsed id round-trips",        parsed_req.id == "corr-1")
check("parsed verb round-trips",      parsed_req.verb == "import_timeline")
check("parsed drt_path round-trips",
    parsed_req.args.drt_path == "/tmp/jve/out.drt")
check("parsed change_token.mutation_generation round-trips (number, not string)",
    parsed_req.args.change_token.mutation_generation == 42)

-- ─── response success build/parse ────────────────────────────────────
local ok_str = protocol.build_response_ok("corr-1", {
    mapping = { { jve_guid = "c-1", resolve_item_id = "r-1" } },
    unrelinked = {},
})
local parsed_ok = protocol.parse_response(ok_str)
check("ok response: ok=true",         parsed_ok.ok == true)
check("ok response: same id",         parsed_ok.id == "corr-1")
check("ok response: result.mapping[1].jve_guid round-trips",
    parsed_ok.result.mapping[1].jve_guid == "c-1")

-- ─── response error build/parse (structured, not bare string) ────────
local err_str = protocol.build_response_error("corr-1",
    "handle_stale", "Resolve handle could not be reacquired")
local parsed_err = protocol.parse_response(err_str)
check("error response: ok=false",     parsed_err.ok == false)
check("error response: error.code",   parsed_err.error.code == "handle_stale")
check("error response: error.message readable",
    parsed_err.error.message:find("Resolve") ~= nil)
-- Closed-code-set surface: known codes are recognised; unknown codes
-- parse but are not silently treated as known.
check("known error code recognised",
    protocol.is_known_error_code("handle_stale") == true)
check("unknown error code surfaced",
    protocol.is_known_error_code("vibes_off") == false)

-- ─── idempotency key derives from change_token, NOT from id ──────────
-- Same change_token + same verb + same args ⇒ same key. Different id
-- with the same args ⇒ same key (re-send returns prior result).
local req_resend = protocol.build_request({
    id   = "corr-99",  -- different correlation id
    verb = "import_timeline",
    args = {
        drt_path     = "/tmp/jve/out.drt",
        media_roots  = { "/Volumes/Media" },
        change_token = change_token,
    },
})
local k1 = protocol.idempotency_key(protocol.parse_request(req_str))
local k2 = protocol.idempotency_key(protocol.parse_request(req_resend))
check("idempotency key ignores id (same args ⇒ same key)", k1 == k2)

-- Same id with a different change_token (different mutation_generation)
-- ⇒ different key (a new state-changing call gets re-run, not replayed).
local req_bumped = protocol.build_request({
    id   = "corr-1",
    verb = "import_timeline",
    args = {
        drt_path     = "/tmp/jve/out.drt",
        media_roots  = { "/Volumes/Media" },
        change_token = {
            project_id = "p-7",
            sequence_id = "s-3",
            mutation_generation = 43,  -- bumped
        },
    },
})
local k3 = protocol.idempotency_key(protocol.parse_request(req_bumped))
check("idempotency key bumps when change_token bumps", k1 ~= k3)

-- Non-state-changing verbs (ping / read_*) have no change_token; their
-- idempotency key MUST be nil so the helper ledger doesn't store
-- replay state for them.
local ping_req = protocol.parse_request(protocol.build_request({
    id   = "corr-ping",
    verb = "ping",
    args = {},
}))
check("ping has nil idempotency key (not state-changing)",
    protocol.idempotency_key(ping_req) == nil)

-- ─── malformed envelopes fail loudly ─────────────────────────────────
expect_error("missing v field rejected", function()
    protocol.parse_request('{"id":"x","verb":"ping","args":{}}\n')
end, "v")
expect_error("missing id rejected", function()
    protocol.parse_request('{"v":1,"verb":"ping","args":{}}\n')
end, "id")
expect_error("non-JSON rejected", function()
    protocol.parse_request("this is not json\n")
end)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_resolve_bridge_protocol.lua: failures present")
print("✅ test_resolve_bridge_protocol.lua passed")
