require("test_env")

local Signals = require("core.signals")
local error_system = require("core.error_system")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== Signals Tests (T13) ===")

-- Clean state before each section
local function fresh()
    Signals.clear_all()
end

-- ============================================================
-- connect — validation errors
-- ============================================================
print("\n--- connect validation ---")
do
    fresh()
    local r1 = Signals.connect(nil, function() end)
    check("nil signal_name → error", error_system.is_error(r1))
    check("nil signal_name code", r1.code == "INVALID_SIGNAL_NAME")

    local r2 = Signals.connect(42, function() end)
    check("number signal_name → error", error_system.is_error(r2))
    check("number signal_name code", r2.code == "INVALID_SIGNAL_NAME")

    local r3 = Signals.connect("", function() end)
    check("empty signal_name → error", error_system.is_error(r3))
    check("empty signal_name code", r3.code == "EMPTY_SIGNAL_NAME")

    local r4 = Signals.connect("test", "not_a_function")
    check("string handler → error", error_system.is_error(r4))
    check("string handler code", r4.code == "INVALID_HANDLER")

    local r5 = Signals.connect("test", nil)
    check("nil handler → error", error_system.is_error(r5))
    check("nil handler code", r5.code == "INVALID_HANDLER")

    local r6 = Signals.connect("test", function() end, "bad")
    check("string priority → error", error_system.is_error(r6))
    check("string priority code", r6.code == "INVALID_PRIORITY")
end

-- ============================================================
-- connect — valid connections
-- ============================================================
print("\n--- connect valid ---")
do
    fresh()
    local id1 = Signals.connect("test_signal", function() end)
    check("returns connection id (number)", type(id1) == "number")
    check("connection id > 0", id1 > 0)

    local id2 = Signals.connect("test_signal", function() end)
    check("second connection different id", id2 ~= id1)
    check("second id incremented", id2 > id1)

    -- Default priority = 100
    local rec = Signals._debug_get_connection(id1)
    check("default priority = 100", rec.priority == 100)
    check("handler stored", type(rec.handler) == "function")
    check("signal_name stored", rec.signal_name == "test_signal")
    check("creation_trace captured", type(rec.creation_trace) == "string")
end

-- ============================================================
-- connect — priority ordering
-- ============================================================
print("\n--- priority ordering ---")
do
    fresh()
    local order = {}
    Signals.connect("ordered", function() table.insert(order, "C") end, 300)
    Signals.connect("ordered", function() table.insert(order, "A") end, 10)
    Signals.connect("ordered", function() table.insert(order, "B") end, 100)

    Signals.emit("ordered")
    check("priority order[1] = A", order[1] == "A")
    check("priority order[2] = B", order[2] == "B")
    check("priority order[3] = C", order[3] == "C")
end

-- ============================================================
-- connect — same priority preserves insertion order
-- ============================================================
print("\n--- same priority insertion order ---")
do
    fresh()
    local order = {}
    Signals.connect("same_p", function() table.insert(order, "first") end, 100)
    Signals.connect("same_p", function() table.insert(order, "second") end, 100)
    Signals.connect("same_p", function() table.insert(order, "third") end, 100)

    Signals.emit("same_p")
    check("same priority[1] = first", order[1] == "first")
    check("same priority[2] = second", order[2] == "second")
    check("same priority[3] = third", order[3] == "third")
end

-- ============================================================
-- disconnect — validation & behavior
-- ============================================================
print("\n--- disconnect ---")
do
    fresh()
    local r1 = Signals.disconnect("not_a_number")
    check("string id → error", error_system.is_error(r1))
    check("string id code", r1.code == "INVALID_CONNECTION_ID")

    local r2 = Signals.disconnect(999999)
    check("nonexistent id → error", error_system.is_error(r2))
    check("nonexistent id code", r2.code == "CONNECTION_NOT_FOUND")

    -- Valid disconnect
    local called = false
    local id = Signals.connect("disc_test", function() called = true end)
    local r3 = Signals.disconnect(id)
    check("disconnect success", error_system.is_success(r3))

    Signals.emit("disc_test")
    check("handler not called after disconnect", not called)

    -- Double disconnect
    local r4 = Signals.disconnect(id)
    check("double disconnect → not found", error_system.is_error(r4))
    check("double disconnect code", r4.code == "CONNECTION_NOT_FOUND")
end

-- ============================================================
-- disconnect — registry cleanup
-- ============================================================
print("\n--- disconnect cleanup ---")
do
    fresh()
    local id = Signals.connect("cleanup_sig", function() end)
    Signals.disconnect(id)

    -- Signal registry should be cleaned up (empty list removed)
    local signals = Signals.list_signals()
    local found = false
    for _, s in ipairs(signals) do
        if s.name == "cleanup_sig" then found = true end
    end
    check("empty signal removed from registry", not found)
end

-- ============================================================
-- emit — validation & no handlers
-- ============================================================
print("\n--- emit ---")
do
    fresh()
    local r1 = Signals.emit(42)
    check("non-string signal → error", error_system.is_error(r1))
    check("non-string signal code", r1.code == "INVALID_SIGNAL_NAME")

    -- No handlers registered
    local r2 = Signals.emit("nobody_listening")
    check("no handlers → empty table", type(r2) == "table" and #r2 == 0)
end

-- ============================================================
-- emit — arguments passed to handlers
-- ============================================================
print("\n--- emit with args ---")
do
    fresh()
    local captured_a, captured_b, captured_c
    Signals.connect("args_test", function(a, b, c)
        captured_a = a
        captured_b = b
        captured_c = c
    end)

    Signals.emit("args_test", "hello", 42, true)
    check("arg 1 passed", captured_a == "hello")
    check("arg 2 passed", captured_b == 42)
    check("arg 3 passed", captured_c == true)
end

-- ============================================================
-- emit — handler error isolation
-- ============================================================
print("\n--- handler error isolation ---")
do
    fresh()
    local before_called = false
    local after_called = false

    Signals.connect("err_test", function() before_called = true end, 10)
    Signals.connect("err_test", function() error("handler crash!") end, 50)
    Signals.connect("err_test", function() after_called = true end, 100)

    local results = Signals.emit("err_test")
    check("before handler called", before_called)
    check("after handler called despite error", after_called)
    check("3 results returned", #results == 3)

    -- Check individual results
    check("result[1] success", results[1].success == true)
    check("result[2] failed", results[2].success == false)
    check("result[2] has error field", results[2].error ~= nil)
    check("result[2] error contains message", tostring(results[2].error):find("handler crash"))
    check("result[3] success", results[3].success == true)

    -- Each result has connection_id
    check("result[1] has connection_id", type(results[1].connection_id) == "number")
end

-- ============================================================
-- emit — handler return values captured
-- ============================================================
print("\n--- handler return values ---")
do
    fresh()
    Signals.connect("ret_test", function() return "value_a" end)
    Signals.connect("ret_test", function() return 42 end)

    local results = Signals.emit("ret_test")
    check("result[1] value", results[1].result == "value_a")
    check("result[2] value", results[2].result == 42)
end

-- ============================================================
-- list_signals
-- ============================================================
print("\n--- list_signals ---")
do
    fresh()
    local empty = Signals.list_signals()
    check("empty registry → empty list", #empty == 0)

    Signals.connect("sig_a", function() end)
    Signals.connect("sig_a", function() end)
    Signals.connect("sig_b", function() end)

    local list = Signals.list_signals()
    check("2 signals in list", #list == 2)

    -- Find counts
    local counts = {}
    for _, s in ipairs(list) do
        counts[s.name] = s.handler_count
    end
    check("sig_a has 2 handlers", counts["sig_a"] == 2)
    check("sig_b has 1 handler", counts["sig_b"] == 1)
end

-- ============================================================
-- clear_all
-- ============================================================
print("\n--- clear_all ---")
do
    Signals.connect("will_be_cleared", function() end)
    local r = Signals.clear_all()
    check("clear_all returns success", error_system.is_success(r))

    local list = Signals.list_signals()
    check("registry empty after clear", #list == 0)

    -- Emit to cleared signal → empty (not error)
    local results = Signals.emit("will_be_cleared")
    check("emit after clear → empty", type(results) == "table" and #results == 0)
end

-- ============================================================
-- hooks facade
-- ============================================================
print("\n--- hooks facade ---")
do
    fresh()
    local hook_called = false
    local hook_arg = nil

    local id = Signals.hooks.add("my_hook", function(x)
        hook_called = true
        hook_arg = x
        return "hook_result"
    end)
    check("hooks.add returns connection id", type(id) == "number")

    local results = Signals.hooks.run("my_hook", "data")
    check("hook called", hook_called)
    check("hook received arg", hook_arg == "data")
    check("hooks.run returns successful results", #results == 1)
    check("hooks.run result value", results[1] == "hook_result")

    -- hooks.run filters out failures
    Signals.hooks.add("mixed_hook", function() return "ok" end, 10)
    Signals.hooks.add("mixed_hook", function() error("fail") end, 50)
    Signals.hooks.add("mixed_hook", function() return "also_ok" end, 100)

    local mixed = Signals.hooks.run("mixed_hook")
    check("hooks.run filters failures", #mixed == 2)
    check("hooks.run[1] = ok", mixed[1] == "ok")
    check("hooks.run[2] = also_ok", mixed[2] == "also_ok")

    -- hooks.remove
    local r = Signals.hooks.remove(id)
    check("hooks.remove returns success", error_system.is_success(r))
end

-- ============================================================
-- emit — no-arg emit
-- ============================================================
print("\n--- emit no args ---")
do
    fresh()
    local called = false
    Signals.connect("no_args", function() called = true end)
    Signals.emit("no_args")
    check("no-arg emit calls handler", called)
end

-- ============================================================
-- multiple signals isolated
-- ============================================================
print("\n--- signal isolation ---")
do
    fresh()
    local a_called = false
    local b_called = false

    Signals.connect("sig_A", function() a_called = true end)
    Signals.connect("sig_B", function() b_called = true end)

    Signals.emit("sig_A")
    check("sig_A handler called", a_called)
    check("sig_B handler NOT called", not b_called)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Signals: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_signals.lua passed")
