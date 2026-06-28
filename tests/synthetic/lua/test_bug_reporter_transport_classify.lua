-- Feature 027: transport classifies wire responses correctly (async API).
--
-- 200 → ok=true with parsed fields surfaced.
-- 429 → ok=false, code="rate_limited", retry_after_seconds surfaced (AS #7 / FR-023).
-- 5xx → ok=false, transient=true (AS #6).
-- network error → ok=false, code="transport".
-- 200 with non-JSON body → ok=false, code="bad_response" surfaced to caller
--   (FR-021a originally said assert; in the async rewrite we surface as a
--   classified result so the on_done callback always fires — see
--   spec-sync TODO in transport.lua).
--
-- Black-box: stub `_G.qt_http_post_json` to return scripted scenarios.

require("test_env")

local transport = require("bug_reporter.transport")

local next_response
local last_request
_G.qt_http_post_json = function(url, headers, body, callback_name)
    last_request = { url = url, headers = headers, body = body, callback_name = callback_name }
    local cb = _G[callback_name]
    if cb then
        cb(next_response.status, next_response.body, next_response.error)
    end
end

local SAMPLE_BODY = {
    install_id = "550e8400-e29b-41d4-a716-446655440000",
    schema_version = "1", jve_sha = "8935293", platform = "Darwin", arch = "arm64",
}

local function post_sync(body)
    local captured
    transport.post_register(body, function(r) captured = r end)
    assert(captured ~= nil, "callback must have fired (stub is synchronous)")
    return captured
end

-- (1) 200 with valid JSON → ok=true with parsed fields.
next_response = { status = 200, body = '{"nonce":"' .. string.rep("a", 64) ..
    '","server_ts":1719279600,"country":"US","timezone":"America/Los_Angeles"}' }
local r = post_sync(SAMPLE_BODY)
assert(r.ok == true, "expected ok=true on 200; got " .. tostring(r.ok))
assert(r.nonce == string.rep("a", 64), "nonce roundtrip broken")
assert(r.country == "US", "country not surfaced")

-- (2) 429 → ok=false, code="rate_limited", retry_after_seconds surfaced.
next_response = { status = 429, body = '{"error":"rate_limited","retry_after_seconds":3600}' }
r = post_sync(SAMPLE_BODY)
assert(r.ok == false, "expected ok=false on 429")
assert(r.code == "rate_limited", "code not surfaced; got " .. tostring(r.code))
assert(r.retry_after_seconds == 3600, "retry_after_seconds not surfaced")

-- (3) 503 → ok=false, code="server_error", transient=true.
next_response = { status = 503, body = '{"error":"upstream_unavailable"}' }
r = post_sync(SAMPLE_BODY)
assert(r.ok == false)
assert(r.transient == true, "503 must surface transient=true; got " .. tostring(r.transient))

-- (4) Network error (status==0 with err) → ok=false, code="transport".
next_response = { status = 0, body = nil, error = "connection refused" }
r = post_sync(SAMPLE_BODY)
assert(r.ok == false)
assert(r.code == "transport", "network error code; got " .. tostring(r.code))

-- (5) 200 with non-JSON body → ok=false, code="bad_response" with endpoint surfaced.
next_response = { status = 200, body = "<html><body>maintenance</body></html>" }
r = post_sync(SAMPLE_BODY)
assert(r.ok == false)
assert(r.code == "bad_response", "non-JSON 200 must surface bad_response; got " .. tostring(r.code))
assert(r.endpoint == "/register", "endpoint must be tagged; got " .. tostring(r.endpoint))
assert(r.reason and r.reason:lower():find("json"),
    "reason must mention json/parse; got " .. tostring(r.reason))
assert(last_request, "callback must have captured the request")

print("✅ test_bug_reporter_transport_classify.lua passed")
