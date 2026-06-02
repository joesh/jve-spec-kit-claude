-- T013 — helper ping contract (spec 023, contracts/helper-protocol.md §ping).
--
-- Spec result shape: `{ alive, resolve_connected, resolve_version,
-- helper_version }`. All four fields are mandatory per the contract;
-- versions are surfaced for the "API-drift landmine" log. Run via
-- `jve --test` (needs qt_process_* / qt_local_socket_* + dkjson).

local fixture = require("binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-ping.sock")

-- ─── ping returns ok=true even with no Resolve attached ─────────────────
-- The contract treats `ping` as liveness: helper alive ⇒ ok=true with
-- `resolve_connected` reflecting the live handle state. Errors are
-- reserved for malformed requests / dead helpers.
local response = fixture.request(fix, "ping", {})

assert(response.ok == true, string.format(
    "ping must return ok=true; got error %s/%s",
    response.error and response.error.code,
    response.error and response.error.message))
assert(protocol.VERSION == response.v, string.format(
    "protocol version mismatch: got v=%s expected %d",
    tostring(response.v), protocol.VERSION))

local result = response.result
assert(type(result) == "table", "result must be a JSON object")

-- ─── shape: all four required fields, no extras forbidden ───────────────
assert(result.alive == true,
    "ping.result.alive must be boolean true")
assert(type(result.resolve_connected) == "boolean",
    "ping.result.resolve_connected must be boolean (got "
    .. type(result.resolve_connected) .. ")")
assert(type(result.resolve_version) == "string"
    and result.resolve_version ~= "",
    "ping.result.resolve_version must be non-empty string")
assert(type(result.helper_version) == "string"
    and result.helper_version ~= "",
    "ping.result.helper_version must be non-empty string")

print(string.format(
    "  ✓ ping shape: alive=%s connected=%s resolve=%q helper=%q",
    tostring(result.alive),
    tostring(result.resolve_connected),
    result.resolve_version,
    result.helper_version))

-- ─── idempotency: re-ping yields same shape, different correlation ──────
-- `ping` is non-state-changing (no change_token); fixture.request mints a
-- fresh correlation id each call. Two back-to-back pings must both
-- conform to the contract.
local second = fixture.request(fix, "ping", {})
assert(second.ok == true, "second ping must also be ok")
assert(second.id ~= response.id, "correlation ids must differ across calls")
assert(second.result.alive == true, "alive must stay true")
assert(second.result.helper_version == result.helper_version,
    "helper_version must be stable across calls within one process")

print("  ✓ second ping shape identical (correlation id rotated)")

-- ─── error contract: bad_request on malformed args ─────────────────────
-- Sending an int where args expects a JSON object is a protocol violation
-- — the helper must surface `bad_request` (closed-set error code), not
-- crash, not silently coerce.
do
    -- Bypass protocol.build_request (which would assert client-side);
    -- we want to verify *helper-side* validation.
    local bad = '{"v":1,"id":"corr-bad-1","verb":"ping","args":42}\n'
    while #fix._chunks > 0 do table.remove(fix._chunks) end
    local n = qt_local_socket_write(fix.sock, bad)
    assert(n == #bad, "partial write of bad envelope")
    qt_local_socket_flush(fix.sock)
    local deadline = 500
    while #fix._chunks == 0 and deadline > 0 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
        deadline = deadline - 1
    end
    assert(#fix._chunks > 0, "helper did not respond to bad envelope")
    local line = table.concat(fix._chunks)
    local parsed = protocol.parse_response(line:sub(1, -2))
    assert(parsed.ok == false,
        "malformed args must produce ok=false, not silent coercion")
    assert(protocol.is_known_error_code(parsed.error.code), string.format(
        "error code %q not in the closed set", parsed.error.code))
    assert(parsed.error.code == "bad_request", string.format(
        "expected bad_request for non-object args, got %q",
        parsed.error.code))
    print("  ✓ malformed args → bad_request (closed-set code)")
end

fixture.stop(fix)

print("✅ test_helper_ping.lua passed")
