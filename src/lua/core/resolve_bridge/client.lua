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
--- callbacks by correlation id. Each in-flight request arms a single-shot
--- `request_timeout_ms` timer that fires `resolve_api_error` /
--- "request timed out after Nms" to on_complete if no reply arrives —
--- never a silent drop (FR-007). A reply that beats the timer wins the
--- race by clearing in_flight; the timer callback no-ops on missing slot.

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

    -- Forward-declared so the malformed-line branch in dispatch_line
    -- can close the socket; self:close is the canonical teardown that
    -- already drains in_flight with a structured error.
    local self_close

    local function fail_all_in_flight(code, message)
        for corr_id, slot in pairs(in_flight) do
            in_flight[corr_id] = nil
            slot.on_complete(nil, code, message)
        end
    end

    local function dispatch_line(line)
        if line == "" then return end
        local ok, parsed = pcall(protocol.parse_response, line .. "\n")
        if not ok then
            -- Wire-level corruption: the helper sent bytes the parser
            -- can't interpret. Don't silently log and continue — the
            -- helper is broken or the socket is desynced, and any
            -- subsequent line could be misattributed. Fail every
            -- in-flight caller with a structured error and close
            -- (rule 2.32 — no silent failure of an entire response
            -- stream; review item #10).
            log.error("client: malformed response line: %s",
                tostring(parsed))
            fail_all_in_flight("resolve_api_error",
                string.format(
                    "client: malformed wire response from helper "
                    .. "(%s); closing socket — every in-flight request "
                    .. "now surfaces as a structured error",
                    tostring(parsed)))
            if self_close then self_close() end
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

    -- Capture the last QLocalSocket error so the connect-failure branch
    -- below can surface what actually happened instead of always saying
    -- "timed out". QLocalSocket::waitForConnected returns false in
    -- multiple distinct cases:
    --   • ServerNotFoundError — socket file doesn't exist (fires
    --     INSTANTLY, NOT after the timeout — cost ~1hr session time
    --     during the spec-023 spawn-race investigation before the real
    --     cause was found; the misleading "timed out" message sent the
    --     debugger after a phantom slow-path).
    --   • ConnectionRefusedError — socket file exists but no listen().
    --   • PeerClosedError — disconnected during handshake.
    --   • SocketTimeoutError / no error cb fired — the genuine timeout.
    -- We branch on err_name so each failure mode self-describes (rule
    -- 2.32 — no silent failure of the actual cause).
    local last_socket_error = nil
    qt_local_socket_set_error_cb(handle, function(err_name)
        last_socket_error = err_name
        log.event("client: socket error: %s", err_name)
    end)

    qt_local_socket_connect(handle, socket_path)
    local connected = qt_local_socket_wait_for_connected(
        handle, connect_timeout_ms)
    if not connected then
        qt_local_socket_destroy(handle)
        local err = last_socket_error
        if err == "ServerNotFoundError" then
            return nil, string.format(
                "client.connect: socket file %s does not exist — "
                .. "QLocalSocket fired ServerNotFoundError instantly "
                .. "(it does NOT retry within its %dms timeout for "
                .. "this error; the caller owns wait-for-bind)",
                socket_path, connect_timeout_ms)
        end
        if err == "ConnectionRefusedError" then
            return nil, string.format(
                "client.connect: connection refused on %s — socket "
                .. "file exists but the helper is not listen()ing",
                socket_path)
        end
        if err == "PeerClosedError" then
            return nil, string.format(
                "client.connect: helper disconnected during connect "
                .. "handshake on %s", socket_path)
        end
        if err then
            return nil, string.format(
                "client.connect: %s on %s (waited up to %dms)",
                err, socket_path, connect_timeout_ms)
        end
        -- No QLocalSocket error cb fired before wait timed out: the
        -- helper accepted then never replied, or the kernel queued
        -- the connect indefinitely. This is the genuine timeout.
        return nil, string.format(
            "client.connect: timed out after %dms with no "
            .. "QLocalSocket error (helper unresponsive on %s?)",
            connect_timeout_ms, socket_path)
    end

    -- opts.timeout_ms (optional): override the client's default
    -- request_timeout_ms for THIS request only. Used by long-running
    -- verbs that legitimately exceed the conservative default (e.g.
    -- read_grades with bake_lut_dir bakes 1000+ LUTs over several
    -- minutes; the default 30s would trip mid-bake and the helper
    -- would then post an "unknown id" reply when it eventually
    -- finished). Must be a positive number; rejected otherwise to
    -- keep the closed-set discipline at the boundary (rule 2.32).
    function self:request(verb, args, on_complete, opts)  -- luacheck: ignore self
        assert(not closed, "client:request: socket is closed")
        assert(type(on_complete) == "function",
            "client:request: on_complete required")
        local effective_timeout_ms = request_timeout_ms
        if opts ~= nil then
            assert(type(opts) == "table",
                "client:request: opts must be table when supplied")
            if opts.timeout_ms ~= nil then
                assert(type(opts.timeout_ms) == "number"
                        and opts.timeout_ms > 0,
                    "client:request: opts.timeout_ms must be positive "
                    .. "number")
                effective_timeout_ms = opts.timeout_ms
            end
        end
        local corr_id = mint_correlation_id()
        in_flight[corr_id] = { on_complete = on_complete }
        local line = protocol.build_request({
            id = corr_id, verb = verb, args = args,
        })
        local written, werr = qt_local_socket_write(handle, line)
        if written == nil then
            in_flight[corr_id] = nil
            assert(type(werr) == "string" and werr ~= "",
                "client:request: qt_local_socket_write returned nil "
                .. "without an error string (FFI contract violation)")
            on_complete(nil, "resolve_api_error", werr)
            return
        end
        qt_local_socket_flush(handle)
        qt_create_single_shot_timer(effective_timeout_ms, function()
            local slot = in_flight[corr_id]
            if slot == nil then return end
            in_flight[corr_id] = nil
            slot.on_complete(nil, "resolve_api_error", string.format(
                "request timed out after %dms (verb=%s)",
                effective_timeout_ms, verb))
        end)
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

    -- Bind the forward declaration used by dispatch_line's malformed-
    -- response branch (Lua closures can't reach a method defined later
    -- in the constructor unless we stash the reference here).
    self_close = function() self:close() end

    return self
end

return M
