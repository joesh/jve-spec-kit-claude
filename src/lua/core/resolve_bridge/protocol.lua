--- Resolve bridge protocol — envelope build/parse (spec 023, T018, FR-008).
---
--- Wire format (per `specs/023-resolve-color-bridge/contracts/helper-
--- protocol.md`): one JSON object per line over Unix domain socket.
---
--- Request:   `{"v":1,"id":"<corr>","verb":"<name>","args":{...}}`
--- Response:  `{"v":1,"id":"<corr>","ok":true,"result":{...}}`
---            `{"v":1,"id":"<corr>","ok":false,"error":{"code":"<machine>","message":"<human>"}}`
---
--- `id` is correlation-only. Idempotency keys derive from
--- `args.change_token` (FR-008), NOT from `id`. Errors are structured
--- (closed code set + human message); never bare strings.

local M = {}

local json = require("dkjson")

local PROTOCOL_VERSION = 1
M.VERSION = PROTOCOL_VERSION

-- Closed error-code set (helper-protocol.md). Extend by bumping VERSION.
local KNOWN_ERROR_CODES = {
    not_studio = true,
    handle_stale = true,
    relink_failed = true,
    locale_rate_corruption = true,
    identity_field_missing = true,
    bad_request = true,
    resolve_api_error = true,
}

function M.is_known_error_code(code)
    return KNOWN_ERROR_CODES[code] == true
end

local function encode_line(tbl)
    local s = json.encode(tbl)
    assert(s and not s:find("\n"),
        "protocol: encoded message contained newline — refusing to write")
    return s .. "\n"
end

-- ─── Request build/parse ────────────────────────────────────────────────

function M.build_request(req)
    assert(type(req) == "table",
        "protocol.build_request: req table required")
    assert(type(req.id) == "string" and req.id ~= "",
        "protocol.build_request: req.id required")
    assert(type(req.verb) == "string" and req.verb ~= "",
        "protocol.build_request: req.verb required")
    assert(type(req.args) == "table",
        "protocol.build_request: req.args table required")
    return encode_line({
        v    = PROTOCOL_VERSION,
        id   = req.id,
        verb = req.verb,
        args = req.args,
    })
end

local function parse_envelope(line, who)
    assert(type(line) == "string" and line ~= "",
        "protocol.parse_" .. who .. ": line required")
    local obj, _, err = json.decode(line)
    assert(obj and type(obj) == "table", string.format(
        "protocol.parse_%s: not a JSON object (%s)",
        who, tostring(err)))
    assert(obj.v == PROTOCOL_VERSION, string.format(
        "protocol.parse_%s: missing/unsupported `v` (got %s, expected %d)",
        who, tostring(obj.v), PROTOCOL_VERSION))
    assert(type(obj.id) == "string" and obj.id ~= "", string.format(
        "protocol.parse_%s: missing `id` correlation field", who))
    return obj
end

function M.parse_request(line)
    local obj = parse_envelope(line, "request")
    assert(type(obj.verb) == "string" and obj.verb ~= "",
        "protocol.parse_request: missing `verb`")
    assert(type(obj.args) == "table",
        "protocol.parse_request: missing `args`")
    return obj
end

-- ─── Response build/parse ───────────────────────────────────────────────

function M.build_response_ok(id, result)
    assert(type(id) == "string" and id ~= "",
        "protocol.build_response_ok: id required")
    assert(type(result) == "table",
        "protocol.build_response_ok: result table required")
    return encode_line({
        v = PROTOCOL_VERSION, id = id, ok = true, result = result,
    })
end

function M.build_response_error(id, code, message)
    assert(type(id) == "string" and id ~= "",
        "protocol.build_response_error: id required")
    assert(type(code) == "string" and code ~= "",
        "protocol.build_response_error: code required")
    assert(type(message) == "string" and message ~= "",
        "protocol.build_response_error: message required (structured "
        .. "error, not bare string)")
    return encode_line({
        v = PROTOCOL_VERSION, id = id, ok = false,
        error = { code = code, message = message },
    })
end

function M.parse_response(line)
    local obj = parse_envelope(line, "response")
    assert(obj.ok == true or obj.ok == false,
        "protocol.parse_response: `ok` must be boolean")
    if obj.ok then
        assert(type(obj.result) == "table",
            "protocol.parse_response: ok=true response missing `result`")
    else
        assert(type(obj.error) == "table"
            and type(obj.error.code) == "string"
            and type(obj.error.message) == "string",
            "protocol.parse_response: error response must carry "
            .. "`error.{code,message}` (structured, never bare string)")
    end
    return obj
end

-- ─── Idempotency key (FR-008) ───────────────────────────────────────────
--
-- Returns a stable string key for a parsed request, derived from
-- (verb, change_token). Same change_token + verb ⇒ same key regardless
-- of `id`. Non-state-changing verbs (no change_token in args) → nil.

local STATE_CHANGING_VERBS_REQUIRE_TOKEN = {
    import_timeline = true,
    queue_render = true,
}

function M.idempotency_key(parsed_request)
    assert(type(parsed_request) == "table"
        and type(parsed_request.verb) == "string"
        and type(parsed_request.args) == "table",
        "protocol.idempotency_key: parsed_request must have verb + args")
    local ct = parsed_request.args.change_token
    if ct == nil then
        assert(not STATE_CHANGING_VERBS_REQUIRE_TOKEN[parsed_request.verb],
            string.format(
                "protocol.idempotency_key: state-changing verb '%s' "
                .. "missing change_token (FR-008)", parsed_request.verb))
        return nil
    end
    assert(type(ct) == "table"
        and type(ct.project_id) == "string"
        and type(ct.sequence_id) == "string"
        and type(ct.mutation_generation) == "number",
        "protocol.idempotency_key: change_token must be "
        .. "{project_id, sequence_id, mutation_generation}")
    return string.format("%s|%s|%s|%d",
        parsed_request.verb,
        ct.project_id, ct.sequence_id, ct.mutation_generation)
end

return M
