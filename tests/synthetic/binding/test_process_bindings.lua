-- T019 — qt_process_* binding smoke (run via `jve --test`).
--
-- Black-box: spawn `echo`, collect stdout, verify exit. Spawn `false`,
-- verify non-zero exit code. Unknown handle ⇒ luaL_error (caller bug).

assert(type(qt_process_create) == "function",
    "qt_process_create binding not registered")
assert(type(qt_process_start) == "function",
    "qt_process_start binding not registered")
assert(type(qt_process_wait_for_started) == "function",
    "qt_process_wait_for_started binding not registered")
assert(type(qt_process_set_finished_cb) == "function",
    "qt_process_set_finished_cb binding not registered")

-- ─── echo round-trip ────────────────────────────────────────────────────
do
    local id = qt_process_create()
    assert(type(id) == "number" and id > 0,
        "create did not return a positive integer id")

    local stdout_chunks = {}
    qt_process_set_stdout_cb(id, function(chunk)
        stdout_chunks[#stdout_chunks + 1] = chunk
    end)

    local finished = { code = nil, status = nil }
    qt_process_set_finished_cb(id, function(code, status)
        finished.code = code
        finished.status = status
    end)

    qt_process_start(id, "/bin/echo", { "hello", "world" })
    assert(qt_process_wait_for_started(id, 5000),
        "echo did not start within 5s")

    local deadline_iters = 250  -- ~5s @ 20ms naps
    while finished.code == nil and deadline_iters > 0 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
        deadline_iters = deadline_iters - 1
    end
    assert(finished.code ~= nil,
        "echo did not finish (exit cb never fired)")
    assert(finished.code == 0,
        string.format("echo exit code %d (expected 0)", finished.code))
    assert(finished.status == "normal",
        "echo exit status: " .. tostring(finished.status))

    local out = table.concat(stdout_chunks)
    assert(out:find("hello world", 1, true),
        "stdout missing 'hello world': " .. tostring(out))
    print(string.format("  ✓ echo: %s", out:gsub("%s+$", "")))

    qt_process_destroy(id)
end

-- ─── non-zero exit ──────────────────────────────────────────────────────
do
    local id = qt_process_create()
    local finished = { code = nil }
    qt_process_set_finished_cb(id, function(code) finished.code = code end)
    qt_process_start(id, "/usr/bin/false", {})
    assert(qt_process_wait_for_started(id, 5000), "false did not start")

    local deadline_iters = 250
    while finished.code == nil and deadline_iters > 0 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
        deadline_iters = deadline_iters - 1
    end
    assert(finished.code ~= 0,
        "false reported exit code 0 — that cannot be right")
    print(string.format("  ✓ false exited %d (non-zero)", finished.code))
    qt_process_destroy(id)
end

-- ─── unknown handle raises ──────────────────────────────────────────────
do
    local ok, err = pcall(qt_process_state, 999999)
    assert(not ok, "qt_process_state on unknown handle should error")
    assert(tostring(err):find("unknown handle"),
        "error message missing 'unknown handle': " .. tostring(err))
    print("  ✓ unknown handle → luaL_error")
end

print("✅ test_process_bindings.lua passed")
