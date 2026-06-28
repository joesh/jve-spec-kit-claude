-- Async transport for the bug-reporter pipeline (Cloudflare Worker).
--
-- The helper mints a global callback slot, hands its name to the
-- truly-async qt_http_post_* binding, and the slot CLEARS ITSELF when
-- the reply arrives. Callers must never touch the slot — doing so was
-- the bug that made every prod POST silently lose its response
-- (pre-rewrite transport set _G[name]=nil right after the post call
-- and returned the still-nil result_holder).

local dkjson = require("dkjson")

local M = {}

local DEFAULT_URL = "https://jve-bug-relay.jve-bugs.workers.dev"
local PROD_URL = os.getenv("JVE_BUG_REPORT_ENDPOINT") or DEFAULT_URL
assert(PROD_URL:sub(1, 8) == "https://",
    "bug_reporter.transport: endpoint MUST be https://; got " .. PROD_URL)

local SCHEMA_VERSION = "1"

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- Top-level alphabetical key ordering so the bytes the Lua side signs
-- match the bytes the Worker re-derives the HMAC over. dkjson's
-- keyorder applies only to the top-level table; the wire bodies in
-- this module are flat, so that's sufficient. Any future nested body
-- must extend this helper to sort recursively.
local function encode_sorted(value)
    return dkjson.encode(value, { keyorder = sorted_keys(value), indent = false })
end

local function classify_response(endpoint, status, body, err)
    if status == 0 then
        assert(err and err ~= "",
            "transport.classify_response: status==0 must carry a non-empty err string per binding contract")
        return { ok = false, code = "transport", error_message = err, endpoint = endpoint }
    end
    if status >= 500 then
        return { ok = false, code = "server_error", transient = true, status = status, endpoint = endpoint }
    end
    if not body or body == "" then
        return { ok = false, code = "bad_response", reason = "empty body", status = status, endpoint = endpoint }
    end
    local decoded, _, perr = dkjson.decode(body)
    if not decoded then
        return { ok = false, code = "bad_response",
            reason = "JSON parse: " .. tostring(perr),
            status = status,
            endpoint = endpoint }
    end
    if status == 200 or status == 201 then
        decoded.ok = true
        return decoded
    end
    assert(decoded.error,
        "transport: Worker contract violation — non-2xx response from " .. endpoint ..
        " (status " .. status .. ") must carry an .error field; got: " .. body)
    return {
        ok = false,
        code = decoded.error,
        status = status,
        endpoint = endpoint,
        retry_after_seconds = decoded.retry_after_seconds,
    }
end

local cb_seq = 0
local function mint_cb_slot(endpoint, on_done)
    cb_seq = cb_seq + 1
    local cb_name = "_bug_reporter_transport_cb_" .. tostring(cb_seq)
    _G[cb_name] = function(status, body, err)
        _G[cb_name] = nil
        on_done(classify_response(endpoint, status, body, err))
    end
    return cb_name
end

local function signed_headers(install_id, nonce, signed_payload, extra)
    assert(install_id and nonce, "transport: install_id + nonce required for signed request")
    local h = {
        ["X-Install-Id"] = install_id,
        ["X-Schema-Version"] = SCHEMA_VERSION,
        ["X-HMAC"] = qt_hmac_sha256(nonce, signed_payload),
    }
    if extra then
        for k, v in pairs(extra) do h[k] = v end
    end
    return h
end

function M.post_register(body, on_done)
    assert(type(body) == "table", "post_register: body must be table")
    assert(type(on_done) == "function", "post_register: on_done callback required")
    local body_str = encode_sorted(body)
    local cb_name = mint_cb_slot("/register", on_done)
    qt_http_post_json(PROD_URL .. "/register",
        { ["Content-Type"] = "application/json" },
        body_str, cb_name)
end

function M.post_heartbeat(body, install_id, nonce, on_done)
    assert(type(body) == "table", "post_heartbeat: body must be table")
    assert(type(on_done) == "function", "post_heartbeat: on_done callback required")
    local body_str = encode_sorted(body)
    local headers = signed_headers(install_id, nonce, body_str,
        { ["Content-Type"] = "application/json" })
    local cb_name = mint_cb_slot("/heartbeat", on_done)
    qt_http_post_json(PROD_URL .. "/heartbeat", headers, body_str, cb_name)
end

function M.post_report(metadata_json, zip_bytes, local_id, install_id, nonce, on_done)
    assert(type(metadata_json) == "string", "post_report: metadata_json must be string")
    assert(type(zip_bytes) == "string", "post_report: zip_bytes must be string")
    assert(type(local_id) == "string" and #local_id > 0,
        "post_report: local_id required (must be stable across retries to enable Worker idempotency)")
    assert(type(on_done) == "function", "post_report: on_done callback required")
    local signed_payload = metadata_json .. "\n" .. qt_sha256(zip_bytes)
    local headers = signed_headers(install_id, nonce, signed_payload,
        { ["X-Report-Local-Id"] = local_id })
    local cb_name = mint_cb_slot("/report", on_done)
    qt_http_post_multipart(PROD_URL .. "/report", headers, {
        { name = "metadata", content_type = "application/json", body = metadata_json },
        -- Worker's parse_multipart requires `payload instanceof Blob`, which
        -- in Cloudflare/fetch only happens when the part has a filename.
        -- Without it, formData() returns a string and parse fails 400.
        { name = "payload",  content_type = "application/zip",  filename = "payload.zip", body = zip_bytes },
    }, cb_name)
end

return M
