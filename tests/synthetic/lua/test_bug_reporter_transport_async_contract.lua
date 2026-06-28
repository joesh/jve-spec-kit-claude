-- Feature 027 (rewrite): transport API contract.
--
-- The HTTP bindings (qt_http_post_json / qt_http_post_multipart) are
-- truly async: they return immediately and fire the callback later when
-- the QNetworkReply finishes. The previous transport.lua wrote
-- `_G[cb_name] = nil` IMMEDIATELY after the post call and returned
-- result_holder.value — which was always nil. Every production POST
-- silently failed; the response body was thrown away.
--
-- The rewrite makes the contract honest: every transport.post_* takes
-- an on_done(result) callback. The callback fires exactly once when
-- the server reply arrives. The cb_name slot frees ITSELF inside the
-- callback so caller-side teardown can never race the reply.
--
-- This test swaps the global qt_http_post_json binding for the duration
-- of one call. That is not a mock of business logic — it satisfies the
-- binding's published contract (cb(status, body, err) fires once) and
-- lets us exercise transport's async semantics without a network round
-- trip. The live-network smoke is a separate test under
-- tests/synthetic/integration.

print("=== test_bug_reporter_transport_async_contract.lua ===")
require("test_env")

local transport = require("bug_reporter.transport")

-- Capture what the binding receives so we can verify transport built
-- the right URL, headers, body. Fire the callback asynchronously
-- (next tick via direct call from within the test — production fires
-- via QNetworkReply::finished signal on the main thread).
local captured = {}
local original_post_json = _G.qt_http_post_json
_G.qt_http_post_json = function(url, headers, body, cb_name)
    captured.url = url
    captured.headers = headers
    captured.body = body
    captured.cb_name = cb_name
end

-- (1) post_register returns immediately (async) — does NOT return the result.
local done_called = false
local done_result = nil
transport.post_register({ install_id = "test-install", schema_version = "1" }, function(result)
    done_called = true
    done_result = result
end)

assert(captured.url:match("/register$"),
    "post_register must POST to /register, got: " .. tostring(captured.url))
assert(captured.cb_name and captured.cb_name ~= "",
    "post_register must register a callback name with the binding")
assert(_G[captured.cb_name] ~= nil,
    "the cb_name slot must hold the callback at the moment the binding fires it (caller MUST NOT have torn it down)")
assert(not done_called,
    "on_done must NOT fire until the binding's callback fires (transport is async)")

-- (2) Fire the binding's callback simulating a successful response.
-- The cb_name slot must clear itself and on_done must be invoked
-- with the parsed result.
local registered_cb = _G[captured.cb_name]
registered_cb(201, '{"nonce":"abc123","country":"US","timezone":"America/Los_Angeles"}', nil)

assert(done_called, "on_done must fire after the binding callback")
assert(done_result.ok == true,
    "201 must be classified ok=true; got: " .. tostring(done_result.ok) ..
    " code=" .. tostring(done_result.code))
assert(done_result.nonce == "abc123",
    "decoded body must surface .nonce; got: " .. tostring(done_result.nonce))
assert(done_result.country == "US",
    "decoded body must surface .country")
assert(_G[captured.cb_name] == nil,
    "callback slot must be self-cleared inside the callback; got: " .. tostring(_G[captured.cb_name]))

-- (3) Network failure path: binding fires with status=0, body=nil, err set.
captured = {}
done_result = nil
transport.post_register({ install_id = "test-install2", schema_version = "1" }, function(result)
    done_called = true
    done_result = result
end)
_G[captured.cb_name](0, nil, "Network unreachable")
assert(done_called, "network-failure path must still invoke on_done")
assert(done_result.ok == false, "network failure must be ok=false")
assert(done_result.code == "transport", "network failure code must be 'transport'")

-- (4) 429 rate-limit response with retry_after_seconds surfaced.
captured = {}
done_result = nil
transport.post_register({ install_id = "test-install3", schema_version = "1" }, function(result)
    done_result = result
end)
_G[captured.cb_name](429, '{"error":"rate_limited","retry_after_seconds":600}', nil)
assert(done_result.ok == false)
assert(done_result.code == "rate_limited", "429 must surface code='rate_limited'")
assert(done_result.retry_after_seconds == 600,
    "429 must surface retry_after_seconds; got: " .. tostring(done_result.retry_after_seconds))

_G.qt_http_post_json = original_post_json
print("✅ test_bug_reporter_transport_async_contract.lua passed")
