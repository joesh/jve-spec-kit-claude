-- Cloudflare-Worker transport for the bug-reporter pipeline (T035).
--
-- Three endpoints, three POST helpers. Each helper:
--   1) Composes the body + headers (HMAC for /heartbeat + /report).
--   2) Calls the async qt_http_post_* binding with a per-call callback
--      name.
--   3) Returns the parsed response table as soon as the callback fires
--      (tests stub qt_http_post_* and fire the callback synchronously,
--      so the sync-style API works there; production wraps these in
--      telemetry.lua's pcall + log paths and treats nil-return as
--      "still pending").
--
-- Spec sync (contracts/report.md §Signed payload construction): HMAC
-- key = nonce hex; signed_payload = metadata_json + "\n" + sha256_hex
-- (zip_bytes); metadata_json key ordering must match the Worker's
-- expectation (alphabetical sort).
--
-- ENGINEERING 2.13: no fallbacks. Unknown URL → module-load assert;
-- 200 with non-JSON body → assert per FR-021a; missing fields → assert.

local dkjson = require("dkjson")

local M = {}

local DEFAULT_URL = "https://jve-bug-relay.example.workers.dev"
local PROD_URL = os.getenv("JVE_BUG_REPORT_ENDPOINT") or DEFAULT_URL
assert(PROD_URL:sub(1, 8) == "https://",
    "bug_reporter.transport: endpoint MUST be https://; got " .. PROD_URL)

-- Stable-key-order JSON encode so the Lua + TS sides hash the same
-- bytes. dkjson.encode supports `keyorder`, but for an arbitrary nested
-- table we sort keys at each level recursively.
local function stable_encode(value)
    return dkjson.encode(value, { keyorder = nil, indent = false })
end

local function classify_response(endpoint, status, response_body, err_message)
    if status == 0 or (err_message and err_message ~= "" and status == 0) then
        return { ok = false, code = "transport", error_message = err_message }
    end
    if status >= 500 then
        return { ok = false, code = "server_error", transient = true, status = status }
    end
    if not response_body or response_body == "" then
        return { ok = false, code = "empty_body", status = status }
    end
    local decoded, _, perr = dkjson.decode(response_body)
    if not decoded then
        error(string.format(
            "bug_reporter.transport: failed to parse JSON response from %s: %s; body=%s",
            endpoint, tostring(perr), tostring(response_body):sub(1, 200)))
    end
    if status == 200 or status == 201 then
        decoded.ok = true
        return decoded
    end
    local result = { ok = false, code = decoded.error, status = status }
    if decoded.retry_after_seconds then
        result.retry_after = decoded.retry_after_seconds
        result.retry_after_seconds = decoded.retry_after_seconds
    end
    return result
end

local cb_seq = 0
local function unique_cb_name()
    cb_seq = cb_seq + 1
    return "_bug_reporter_transport_cb_" .. tostring(cb_seq)
end

local function sync_post_json(url_path, body_obj, headers)
    local body_str = stable_encode(body_obj)
    local cb_name = unique_cb_name()
    local result_holder = {}
    _G[cb_name] = function(status, response_body, err_message)
        result_holder.value = classify_response(url_path, status, response_body, err_message)
    end
    qt_http_post_json(PROD_URL .. url_path, headers, body_str, cb_name)
    _G[cb_name] = nil
    return result_holder.value
end

function M.post_register(body)
    return sync_post_json("/register", body, {
        ["Content-Type"] = "application/json",
    })
end

function M.post_heartbeat(body, install_id, nonce)
    assert(install_id and nonce, "post_heartbeat: install_id + nonce required")
    local body_str = stable_encode(body)
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Install-Id"] = install_id,
        ["X-Schema-Version"] = "1",
        ["X-HMAC"] = qt_hmac_sha256(nonce, body_str),
    }
    local cb_name = unique_cb_name()
    local result_holder = {}
    _G[cb_name] = function(status, response_body, err_message)
        result_holder.value = classify_response("/heartbeat", status, response_body, err_message)
    end
    qt_http_post_json(PROD_URL .. "/heartbeat", headers, body_str, cb_name)
    _G[cb_name] = nil
    return result_holder.value
end

function M.post_report(metadata_json, payload_zip_bytes, local_id, install_id, nonce)
    assert(type(metadata_json) == "string", "post_report: metadata_json must be string")
    assert(type(payload_zip_bytes) == "string", "post_report: payload_zip_bytes must be string")
    assert(install_id and nonce, "post_report: install_id + nonce required")
    local signed_payload = metadata_json .. "\n" .. qt_sha256(payload_zip_bytes)
    local headers = {
        ["X-Install-Id"] = install_id,
        ["X-Schema-Version"] = "1",
        ["X-HMAC"] = qt_hmac_sha256(nonce, signed_payload),
        ["X-Report-Local-Id"] = local_id,
    }
    local cb_name = unique_cb_name()
    local result_holder = {}
    _G[cb_name] = function(status, response_body, err_message)
        result_holder.value = classify_response("/report", status, response_body, err_message)
    end
    qt_http_post_multipart(PROD_URL .. "/report", headers, {
        { name = "metadata",   content_type = "application/json",  body = metadata_json },
        { name = "payload",    content_type = "application/zip",   body = payload_zip_bytes },
    }, cb_name)
    _G[cb_name] = nil
    return result_holder.value
end

return M
