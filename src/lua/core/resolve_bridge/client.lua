--- Resolve bridge client — JVE-side request/response over the helper
--- socket (spec 023, T022, FR-006). Owns:
---   • correlation-id minting + in-flight map
---   • framing (assembles whole `\n`-terminated lines from socket chunks)
---   • envelope build/parse via core.resolve_bridge.protocol
--- Does NOT own:
---   • helper process lifecycle (T023 helper_supervisor)
---   • idempotency (FR-008 lives in the helper's ledger — client only
---     stamps a fresh correlation id on each call and lets the helper
---     decide whether the change_token is a replay)
---
--- API:
---   client.connect(socket_path, opts) -> client_table | nil, err
---     opts.connect_timeout_ms (required) — connect timeout in ms
---     opts.request_timeout_ms (required) — per-request reply timeout
---   client:request(verb, args, on_complete)
---     on_complete(ok_response_table)  on success
---     on_complete(nil, code, message) on structured error
---   client:close()
---
--- The reply path is async: the FFI's readyRead callback drains the socket
--- into a line buffer; complete lines parse + dispatch to in-flight
--- callbacks by correlation id. Timeouts are a structured error
--- ("timeout"), never a silent drop (FR-007).

local protocol = require("core.resolve_bridge.protocol")
local log = require("core.logger").for_area("commands")

local M = {}

local NEXT_CORR_ID = 1
local function mint_correlation_id()
    local id = string.format("jve-%d-%d", os.time(), NEXT_CORR_ID)
    NEXT_CORR_ID = NEXT_CORR_ID + 1
    return id
end

local function require_opt(opts, name)
    assert(opts and type(opts[name]) == "number" and opts[name] > 0,
        string.format("client.connect: opts.%s required (positive number)",
            name))
    return opts[name]
end

function M.connect(socket_path, opts)
    assert(type(socket_path) == "string" and socket_path ~= "",
        "client.connect: socket_path required")
    local connect_timeout_ms = require_opt(opts, "connect_timeout_ms")
    local request_timeout_ms = require_opt(opts, "request_timeout_ms")

    local handle = qt_local_socket_create()
    local in_flight = {}      -- corr_id → { on_complete = fn, timer_id = ... }
    local recv_buffer = ""
    local closed = false

    local self = {
        _handle = handle,
        _in_flight = in_flight,
        _request_timeout_ms = request_timeout_ms,
    }

    local function dispatch_line(line)
        if line == "" then return end
        local ok, parsed = pcall(protocol.parse_response, line .. "\n")
        if not ok then
            log.error("client: malformed response line: %s", tostring(parsed))
            return
        end
        local slot = in_flight[parsed.id]
        if slot == nil then
            log.warn("client: response for unknown id %s", tostring(parsed.id))
            return
        end
        in_flight[parsed.id] = nil
        if parsed.ok then
            slot.on_complete(parsed)
        else
            slot.on_complete(nil,
                parsed.error.code, parsed.error.message)
        end
    end

    qt_local_socket_set_ready_read_cb(handle, function()
        local chunk = qt_local_socket_read_all(handle)
        if chunk == "" then return end
        recv_buffer = recv_buffer .. chunk
        while true do
            local nl = recv_buffer:find("\n", 1, true)
            if not nl then break end
            local line = recv_buffer:sub(1, nl - 1)
            recv_buffer = recv_buffer:sub(nl + 1)
            dispatch_line(line)
        end
    end)

    qt_local_socket_set_disconnected_cb(handle, function()
        closed = true
        for corr_id, slot in pairs(in_flight) do
            in_flight[corr_id] = nil
            slot.on_complete(nil, "resolve_api_error",
                "helper socket disconnected before reply")
        end
    end)

    qt_local_socket_set_error_cb(handle, function(err_name)
        log.event("client: socket error: %s", err_name)
    end)

    qt_local_socket_connect(handle, socket_path)
    local connected = qt_local_socket_wait_for_connected(
        handle, connect_timeout_ms)
    if not connected then
        qt_local_socket_destroy(handle)
        return nil, string.format(
            "client.connect: timed out after %dms (helper not listening?)",
            connect_timeout_ms)
    end

    function self:request(verb, args, on_complete)  -- luacheck: ignore self
        assert(not closed, "client:request: socket is closed")
        assert(type(on_complete) == "function",
            "client:request: on_complete required")
        local corr_id = mint_correlation_id()
        in_flight[corr_id] = { on_complete = on_complete }
        local line = protocol.build_request({
            id = corr_id, verb = verb, args = args,
        })
        local written, werr = qt_local_socket_write(handle, line)
        if written == nil then
            in_flight[corr_id] = nil
            on_complete(nil, "resolve_api_error", werr or "write failed")
            return
        end
        qt_local_socket_flush(handle)
    end

    function self:close()  -- luacheck: ignore self
        if closed then return end
        closed = true
        for corr_id, slot in pairs(in_flight) do
            in_flight[corr_id] = nil
            slot.on_complete(nil, "resolve_api_error",
                "client:close() called before reply")
        end
        qt_local_socket_destroy(handle)
    end

    return self
end

return M
