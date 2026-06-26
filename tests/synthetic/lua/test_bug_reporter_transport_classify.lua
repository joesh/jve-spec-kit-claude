-- Feature 027 T025: transport classifies wire responses correctly.
--
-- 200 → delivered + ref_short surfaced (AS #5).
-- 429 → "over today's cap" surfaced; report discarded locally (AS #7 / FR-023).
-- 5xx → enqueue to pending queue (AS #6).
-- network error → enqueue.
-- 200 with non-JSON body → assert with endpoint + body in message (FR-021a / AS #24).
--
-- Black-box: stub `_G.qt_http_post_json` to return scripted scenarios.

require("test_env")

local function require_or_red(modname, task)
    local ok, mod = pcall(require, modname)
    if not ok then
        error("RED — " .. modname .. " unloadable (" .. task .. " not landed): " .. tostring(mod))
    end
    return mod
end

local transport = require_or_red("bug_reporter.transport", "T035")

-- Stub the HTTP global so each test scripts the next response.
local next_response  -- { status, body_string, error_message? }
local last_request   -- captured for inspection
_G.qt_http_post_json = function(url, headers, body, callback_name)
    last_request = { url = url, headers = headers, body = body, callback_name = callback_name }
    local cb = _G[callback_name]
    if cb then
        cb(next_response.status, next_response.body, next_response.error)
    end
end

-- transport.post_register synchronous-style API (per T025 task description).
local SAMPLE_BODY = {
    install_id = "550e8400-e29b-41d4-a716-446655440000",
    schema_version = "1", jve_sha = "8935293", platform = "Darwin", arch = "arm64",
}

-- (1) 200 with valid JSON → ok=true with parsed fields.
do
    next_response = { status = 200, body = '{"nonce":"' .. string.rep("a", 64) .. '","server_ts":1719279600,"country":"US","timezone":"America/Los_Angeles"}' }
    local result = transport.post_register(SAMPLE_BODY)
    assert(result.ok == true, "expected ok=true on 200; got " .. tostring(result.ok))
    assert(result.nonce == string.rep("a", 64), "nonce roundtrip broken")
    assert(result.country == "US", "country not surfaced")
end

-- (2) 429 → ok=false, code="rate_limited", retry_after surfaced.
do
    next_response = { status = 429, body = '{"error":"rate_limited","retry_after_seconds":3600}' }
    local result = transport.post_register(SAMPLE_BODY)
    assert(result.ok == false, "expected ok=false on 429")
    assert(result.code == "rate_limited", "code not surfaced")
    assert(result.retry_after == 3600 or result.retry_after_seconds == 3600,
        "retry_after not surfaced")
end

-- (3) 503 → ok=false, code="server_error" or similar; caller treats as transient.
do
    next_response = { status = 503, body = '{"error":"upstream_unavailable"}' }
    local result = transport.post_register(SAMPLE_BODY)
    assert(result.ok == false, "expected ok=false on 503")
    -- code should mark it as transient/server.
    assert(result.code and tostring(result.code):find("server")
        or result.transient == true,
        "503 must surface as transient/server error; got code=" .. tostring(result.code))
end

-- (4) Network error (callback receives error_message non-nil) → ok=false, code="transport".
do
    next_response = { status = 0, body = nil, error = "connection refused" }
    local result = transport.post_register(SAMPLE_BODY)
    assert(result.ok == false, "expected ok=false on network error")
    assert(tostring(result.code or ""):find("transport")
        or tostring(result.code or "") == "network"
        or result.error_message,
        "network error must surface as transport/network code; got code=" .. tostring(result.code))
end

-- (5) 200 with non-JSON body → assert with endpoint + 'parse' in message (FR-021a).
do
    next_response = { status = 200, body = "<html><body>maintenance</body></html>" }
    local ok, err = pcall(transport.post_register, SAMPLE_BODY)
    assert(not ok, "expected assert on 200 + non-JSON body")
    local err_s = tostring(err)
    assert(err_s:lower():find("parse") or err_s:lower():find("json"),
        "assert message must mention parse/json; got: " .. err_s)
    assert(err_s:find("register", 1, true) or err_s:find("/register", 1, true)
        or last_request and err_s:find(last_request.url or "", 1, true),
        "assert message must reference the endpoint; got: " .. err_s)
end

print("✅ test_bug_reporter_transport_classify.lua passed")
