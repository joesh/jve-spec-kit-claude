require("test_env")

local error_system = require("core.error_system")
local ErrorBuilder = require("core.error_builder")

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

-- ============================================================
-- error_system.create_error
-- ============================================================
print("\n--- create_error: validation ---")
do
    expect_error("create_error non-table param", function()
        error_system.create_error("not a table")
    end, "params must be a table")

    expect_error("create_error nil message", function()
        error_system.create_error({})
    end, "params.message must be a non%-empty string")

    expect_error("create_error empty message", function()
        error_system.create_error({ message = "" })
    end, "params.message must be a non%-empty string")

    expect_error("create_error numeric message", function()
        error_system.create_error({ message = 42 })
    end, "params.message must be a non%-empty string")
end

print("\n--- create_error: required fields ---")
do
    local err = error_system.create_error({
        message = "test error",
        code = "TEST_ERROR",
        operation = "test_op",
        component = "test_component"
    })
    check("success is false", err.success == false)
    check("message preserved", err.message == "test error")
    check("code preserved", err.code == "TEST_ERROR")
    check("default category", err.category == "system")
    check("default severity", err.severity == "error")
    check("operation preserved", err.operation == "test_op")
    check("component preserved", err.component == "test_component")
    check("default context_stack empty", #err.context_stack == 0)
    check("default technical_details empty", next(err.technical_details) == nil)
    check("default parameters empty", next(err.parameters) == nil)
    check("user_message defaults to message", err.user_message == "test error")
    check("default remediation empty", #err.remediation == 0)
    check("timestamp is number", type(err.timestamp) == "number")
    check("lua_stack captured", type(err.lua_stack) == "string")
end

print("\n--- create_error: all optional fields ---")
do
    local err = error_system.create_error({
        message = "full error",
        code = "MY_CODE",
        category = "qt_widget",
        severity = "critical",
        operation = "create_widget",
        component = "timeline",
        context_stack = {{ operation = "parent", component = "app" }},
        technical_details = { key = "val" },
        parameters = { param1 = "abc" },
        user_message = "Something went wrong",
        remediation = { "Try restarting" },
    })
    check("code set", err.code == "MY_CODE")
    check("category set", err.category == "qt_widget")
    check("severity set", err.severity == "critical")
    check("operation set", err.operation == "create_widget")
    check("component set", err.component == "timeline")
    check("context_stack preserved", #err.context_stack == 1)
    check("technical_details preserved", err.technical_details.key == "val")
    check("parameters preserved", err.parameters.param1 == "abc")
    check("user_message set", err.user_message == "Something went wrong")
    check("remediation preserved", err.remediation[1] == "Try restarting")
end

-- ============================================================
-- error_system.create_success
-- ============================================================
print("\n--- create_success ---")
do
    local s = error_system.create_success({})
    check("success is true", s.success == true)
    check("default message", s.message == "Operation completed successfully")
    check("default return_values empty", next(s.return_values) == nil)
    check("timestamp present", type(s.timestamp) == "number")

    local s2 = error_system.create_success({ message = "done", return_values = { x = 1 } })
    check("custom message", s2.message == "done")
    check("return_values set", s2.return_values.x == 1)
end

-- ============================================================
-- is_error / is_success
-- ============================================================
print("\n--- is_error / is_success ---")
do
    local err = error_system.create_error({ message = "e", code = "TEST", operation = "test", component = "test" })
    local suc = error_system.create_success({})
    check("is_error on error", error_system.is_error(err) == true)
    check("is_error on success", error_system.is_error(suc) == false)
    check("is_success on success", error_system.is_success(suc) == true)
    check("is_success on error", error_system.is_success(err) == false)

    -- edge cases
    check("is_error nil", not error_system.is_error(nil))
    check("is_error string", not error_system.is_error("hello"))
    check("is_error number", not error_system.is_error(42))
    check("is_error empty table", not error_system.is_error({}))
    check("is_success nil", not error_system.is_success(nil))
    check("is_success empty table", not error_system.is_success({}))
end

-- ============================================================
-- add_context
-- ============================================================
print("\n--- add_context ---")
do
    local err = error_system.create_error({ message = "base", code = "TEST", operation = "test", component = "test" })
    local result = error_system.add_context(err, {
        operation = "op1",
        component = "comp1",
        technical_details = { detail1 = "v1" },
        remediation = { "fix1" },
        user_message = "friendly msg",
    })
    check("returns same object", result == err)
    check("context_stack has 1 entry", #err.context_stack == 1)
    check("context operation", err.context_stack[1].operation == "op1")
    check("context component", err.context_stack[1].component == "comp1")
    check("top-level operation updated", err.operation == "op1")
    check("top-level component updated", err.component == "comp1")
    check("technical_details merged", err.technical_details.detail1 == "v1")
    check("remediation appended", err.remediation[1] == "fix1")
    check("user_message overridden", err.user_message == "friendly msg")

    -- second context prepends
    error_system.add_context(err, { operation = "op2", component = "comp2" })
    check("context_stack has 2 entries", #err.context_stack == 2)
    check("newest context at index 1", err.context_stack[1].operation == "op2")
    check("older context at index 2", err.context_stack[2].operation == "op1")

    -- passthrough on success
    local suc = error_system.create_success({})
    local r = error_system.add_context(suc, { operation = "x" })
    check("success passthrough", r == suc)
    check("success has no context_stack", suc.context_stack == nil)

    -- passthrough on nil
    check("nil passthrough", error_system.add_context(nil, { operation = "x" }) == nil)
end

-- ============================================================
-- safe_call
-- ============================================================
print("\n--- safe_call: success path ---")
do
    local fn = function() return error_system.create_success({ message = "ok" }) end
    local r = error_system.safe_call(fn, { operation = "test_op" })
    check("safe_call success", error_system.is_success(r))
    check("safe_call message", r.message == "ok")
end

print("\n--- safe_call: error return path ---")
do
    local fn = function()
        return error_system.create_error({ message = "inner fail", code = "MY_ERR", operation = "inner", component = "test" })
    end
    local r = error_system.safe_call(fn, { operation = "wrap_op", component = "wrap_comp" })
    check("safe_call error propagated", error_system.is_error(r))
    check("safe_call code preserved", r.code == "MY_ERR")
    check("safe_call context added", #r.context_stack > 0)
    check("safe_call operation from context", r.operation == "wrap_op")
end

print("\n--- safe_call: Lua throw path ---")
do
    local fn = function() error("kaboom") end
    local r = error_system.safe_call(fn, { operation = "throwing_fn", component = "test" })
    check("safe_call catches throw", error_system.is_error(r))
    check("safe_call throw code", r.code == "LUA_RUNTIME_ERROR")
    check("safe_call throw message contains original", r.message:find("kaboom") ~= nil)
    check("safe_call throw category", r.category == "lua_engine")
end

print("\n--- safe_call: nil return ---")
do
    local fn = function() return nil end
    local r = error_system.safe_call(fn, { operation = "nil_fn" })
    check("safe_call nil return passthrough", r == nil)
end

print("\n--- safe_call: invalid return type ---")
do
    expect_error("safe_call non-table return", function()
        error_system.safe_call(function() return "bad" end, { operation = "str_fn", component = "test" })
    end, "FATAL.*returned string.*safe_call requires ErrorContext")

    expect_error("safe_call table without .success", function()
        error_system.safe_call(function() return { x = 1 } end, { operation = "nosuccess_fn", component = "test" })
    end, "FATAL.*returned table without .success")
end

-- ============================================================
-- format_user_error
-- ============================================================
print("\n--- format_user_error ---")
do
    expect_error("format_user_error nil", function()
        error_system.format_user_error(nil)
    end, "error_obj cannot be nil")

    -- success result
    local s = error_system.create_success({})
    check("format_user_error success", error_system.format_user_error(s) == "No error to format")

    -- basic error
    local err = error_system.create_error({
        message = "tech msg",
        user_message = "user msg",
        code = "TEST_CODE",
        category = "test_cat",
        operation = "test_op",
        component = "test_comp",
    })
    local formatted = error_system.format_user_error(err)
    check("format contains user_message", formatted:find("user msg") ~= nil)
    check("format contains error code", formatted:find("TEST_CODE") ~= nil)
    check("format contains category", formatted:find("test_cat") ~= nil)

    -- with context, technical details, remediation
    error_system.add_context(err, {
        operation = "my_op", component = "my_comp",
        technical_details = { foo = "bar" },
        remediation = { "Step 1" },
    })
    local fmt2 = error_system.format_user_error(err)
    check("format has context section", fmt2:find("What was happening") ~= nil)
    check("format has technical details", fmt2:find("foo") ~= nil)
    check("format has remediation", fmt2:find("Step 1") ~= nil)
end

-- ============================================================
-- format_debug_error
-- ============================================================
print("\n--- format_debug_error ---")
do
    check("format_debug nil", error_system.format_debug_error(nil) == "No error to format")
    check("format_debug success", error_system.format_debug_error(error_system.create_success({})) == "No error to format")

    local err = error_system.create_error({
        message = "dbg msg",
        code = "DBG_CODE",
        category = "dbg_cat",
        severity = "warning",
        operation = "dbg_op",
        component = "dbg_comp",
        parameters = { p1 = "v1" },
        technical_details = { t1 = "d1" },
    })
    error_system.add_context(err, { operation = "ctx_op", component = "ctx_comp", details = { dk = "dv" } })
    local dbg = error_system.format_debug_error(err)
    check("debug has header", dbg:find("DEBUG ERROR REPORT") ~= nil)
    check("debug has code", dbg:find("DBG_CODE") ~= nil)
    check("debug has severity", dbg:find("warning") ~= nil)
    check("debug has message", dbg:find("dbg msg") ~= nil)
    check("debug has context stack", dbg:find("Context Stack") ~= nil)
    check("debug has parameters", dbg:find("p1") ~= nil)
    check("debug has stack trace", dbg:find("Lua Stack Trace") ~= nil)
    check("debug has footer", dbg:find("END DEBUG REPORT") ~= nil)
end

-- ============================================================
-- assert_type
-- ============================================================
print("\n--- assert_type ---")
do
    -- should not error on correct type
    error_system.assert_type("hello", "string", "name", { operation = "test", component = "test" })
    check("assert_type string passes", true)

    error_system.assert_type(42, "number", "count", { operation = "test", component = "test" })
    check("assert_type number passes", true)

    error_system.assert_type({}, "table", "data", { operation = "test", component = "test" })
    check("assert_type table passes", true)

    expect_error("assert_type wrong type", function()
        error_system.assert_type(42, "string", "name", { operation = "validate", component = "test" })
    end, "Invalid name type")
end

-- ============================================================
-- qt_widget_error
-- ============================================================
print("\n--- qt_widget_error ---")
do
    local ops = { "create", "style", "connect", "layout" }
    for _, op in ipairs(ops) do
        local err = error_system.qt_widget_error(op, "QPushButton", { extra = "info" })
        check("qt_widget_error " .. op .. " is error", error_system.is_error(err))
        check("qt_widget_error " .. op .. " category", err.category == "qt_widget")
        check("qt_widget_error " .. op .. " has remediation", #err.remediation > 0)
        check("qt_widget_error " .. op .. " message", err.message:find("QPushButton") ~= nil)
    end

    -- unknown operation
    local err = error_system.qt_widget_error("unknown_op", "QLabel", {})
    check("qt_widget_error unknown code fallback", err.code == "QT_WIDGET_ERROR")
    check("qt_widget_error unknown has remediation", #err.remediation > 0)
end

-- ============================================================
-- inspector_error
-- ============================================================
print("\n--- inspector_error ---")
do
    local err = error_system.inspector_error("initialization", { section = "metadata" })
    check("inspector_error is error", error_system.is_error(err))
    check("inspector_error code", err.code == "INSPECTOR_INITIALIZATION_FAILED")
    check("inspector_error category", err.category == "inspector")
    check("inspector_error operation", err.operation == "inspector_initialization")
    check("inspector_error has remediation", #err.remediation > 0)
end

-- ============================================================
-- log_detailed_error
-- ============================================================
print("\n--- log_detailed_error ---")
do
    local err = error_system.create_error({ message = "log me", code = "LOG_TEST", operation = "log_op", component = "log_comp" })
    local out = error_system.log_detailed_error(err)
    check("log_detailed_error for error", out:find("DEBUG ERROR REPORT") ~= nil)

    check("log_detailed_error for string", error_system.log_detailed_error("plain") == "plain")
    check("log_detailed_error for number", error_system.log_detailed_error(42) == "42")
    check("log_detailed_error for nil", error_system.log_detailed_error(nil) == "nil")
end

-- ============================================================
-- exports
-- ============================================================
print("\n--- exports ---")
do
    check("CATEGORIES exported", error_system.CATEGORIES ~= nil)
    check("CATEGORIES.QT_WIDGET", error_system.CATEGORIES.QT_WIDGET == "qt_widget")
    check("CATEGORIES.COMMAND", error_system.CATEGORIES.COMMAND == "command")
    check("SEVERITY exported", error_system.SEVERITY ~= nil)
    check("SEVERITY.CRITICAL", error_system.SEVERITY.CRITICAL == "critical")
    check("SEVERITY.INFO", error_system.SEVERITY.INFO == "info")
    check("CODES exported", error_system.CODES ~= nil)
    check("CODES.LUA_RUNTIME_ERROR", error_system.CODES.LUA_RUNTIME_ERROR == "LUA_RUNTIME_ERROR")
    check("CODES.WIDGET_CREATION_FAILED", error_system.CODES.WIDGET_CREATION_FAILED == "WIDGET_CREATION_FAILED")
end

-- ============================================================
-- ErrorBuilder basics
-- ============================================================
print("\n--- ErrorBuilder.new ---")
do
    local b = ErrorBuilder.new("error", "MY_CODE", "test message")
    check("builder created", b ~= nil)
    check("builder has error_data", b.error_data ~= nil)
    check("builder severity", b.error_data.severity == "error")
    check("builder code", b.error_data.code == "MY_CODE")
    check("builder message", b.error_data.message == "test message")
    check("builder default category", b.error_data.category == "general")
    check("builder default operation", b.error_data.operation == "unknown")
    check("builder default component", b.error_data.component == "unknown")
    check("builder user_message defaults to message", b.error_data.user_message == "test message")
end

-- ============================================================
-- ErrorBuilder method chaining
-- ============================================================
print("\n--- ErrorBuilder: method chaining ---")
do
    local b = ErrorBuilder.new("warning", "CHAIN_TEST", "chain")
    local r = b:addContext("k", "v")
    check("addContext returns self", r == b)
    r = b:addContextTable({ a = 1 })
    check("addContextTable returns self", r == b)
    r = b:addSuggestion("s")
    check("addSuggestion returns self", r == b)
    r = b:addSuggestions({ "s2" })
    check("addSuggestions returns self", r == b)
    r = b:addAutoFix("desc", "hint", 90)
    check("addAutoFix returns self", r == b)
    r = b:withAttemptedAction("action")
    check("withAttemptedAction returns self", r == b)
    r = b:withOperation("op")
    check("withOperation returns self", r == b)
    r = b:withComponent("comp")
    check("withComponent returns self", r == b)
    r = b:withCategory("cat")
    check("withCategory returns self", r == b)
    r = b:withUserMessage("um")
    check("withUserMessage returns self", r == b)
    r = b:withTechnicalDetails({ td = 1 })
    check("withTechnicalDetails returns self", r == b)
    r = b:escalate("critical")
    check("escalate returns self", r == b)
    r = b:withTiming(os.time() - 5)
    check("withTiming returns self", r == b)
end

-- ============================================================
-- ErrorBuilder: addContext / addContextTable
-- ============================================================
print("\n--- ErrorBuilder: context methods ---")
do
    local b = ErrorBuilder.new("error", "CTX", "ctx test")
    b:addContext("k1", "v1")
    check("addContext stores value", b.error_data.context.k1 == "v1")

    b:addContext("k2", 42)
    check("addContext converts to string", b.error_data.context.k2 == "42")

    b:addContextTable({ a = "x", b = true })
    check("addContextTable key a", b.error_data.context.a == "x")
    check("addContextTable key b stringified", b.error_data.context.b == "true")

    -- non-table ignored
    b:addContextTable("not a table")
    check("addContextTable non-table no-op", true)
end

-- ============================================================
-- ErrorBuilder: suggestions
-- ============================================================
print("\n--- ErrorBuilder: suggestions ---")
do
    local b = ErrorBuilder.new("error", "SUG", "sug test")
    b:addSuggestion("s1")
    check("addSuggestion count", #b.error_data.suggestions == 1)
    check("addSuggestion value", b.error_data.suggestions[1] == "s1")

    b:addSuggestions({ "s2", "s3" })
    check("addSuggestions count", #b.error_data.suggestions == 3)

    -- non-table ignored
    b:addSuggestions("not a table")
    check("addSuggestions non-table no-op", #b.error_data.suggestions == 3)
end

-- ============================================================
-- ErrorBuilder: addAutoFix
-- ============================================================
print("\n--- ErrorBuilder: addAutoFix ---")
do
    local b = ErrorBuilder.new("error", "FIX", "fix test")
    b:addAutoFix("desc1", "hint1", 80)
    check("autofix count", #b.error_data.auto_fixes == 1)
    check("autofix description", b.error_data.auto_fixes[1].description == "desc1")
    check("autofix code_hint", b.error_data.auto_fixes[1].code_hint == "hint1")
    check("autofix confidence", b.error_data.auto_fixes[1].confidence == 80)

    b:addAutoFix("desc2", "hint2")
    check("autofix default confidence", b.error_data.auto_fixes[2].confidence == 50)
end

-- ============================================================
-- ErrorBuilder: withAttemptedAction
-- ============================================================
print("\n--- ErrorBuilder: withAttemptedAction ---")
do
    local b = ErrorBuilder.new("error", "ACT", "act test")
    b:withAttemptedAction("tried X")
    b:withAttemptedAction("tried Y")
    check("attempted_actions count", #b.error_data.attempted_actions == 2)
    check("attempted_actions[1]", b.error_data.attempted_actions[1] == "tried X")
end

-- ============================================================
-- ErrorBuilder: escalate
-- ============================================================
print("\n--- ErrorBuilder: escalate ---")
do
    local b = ErrorBuilder.new("info", "ESC", "escalate test")
    check("initial severity", b.error_data.severity == "info")

    b:escalate("warning")
    check("escalated to warning", b.error_data.severity == "warning")

    b:escalate("critical")
    check("escalated to critical", b.error_data.severity == "critical")

    -- downgrade ignored
    b:escalate("info")
    check("downgrade ignored", b.error_data.severity == "critical")

    -- same level ignored
    b:escalate("critical")
    check("same level no-op", b.error_data.severity == "critical")
end

-- ============================================================
-- ErrorBuilder: withTiming
-- ============================================================
print("\n--- ErrorBuilder: withTiming ---")
do
    local b = ErrorBuilder.new("error", "TIM", "timing test")
    b:withTiming(os.time() - 10)
    check("timing context added", b.error_data.context.operation_duration_seconds ~= nil)

    -- nil start_value is no-op
    local b2 = ErrorBuilder.new("error", "TIM2", "timing nil")
    b2:withTiming(nil)
    check("withTiming nil no-op", b2.error_data.context.operation_duration_seconds == nil)
end

-- ============================================================
-- ErrorBuilder: withTechnicalDetails
-- ============================================================
print("\n--- ErrorBuilder: withTechnicalDetails ---")
do
    local b = ErrorBuilder.new("error", "TD", "td test")
    b:withTechnicalDetails({ cpu = "arm64", memory = 8192 })
    check("technical_details merged", b.error_data.technical_details.cpu == "arm64")
    check("technical_details number", b.error_data.technical_details.memory == 8192)

    -- non-table ignored
    b:withTechnicalDetails("nope")
    check("withTechnicalDetails non-table no-op", b.error_data.technical_details.cpu == "arm64")
end

-- ============================================================
-- ErrorBuilder: build()
-- ============================================================
print("\n--- ErrorBuilder: build ---")
do
    local b = ErrorBuilder.new("warning", "BUILD_TEST", "build me")
        :withOperation("my_op")
        :withComponent("my_comp")
        :withCategory("qt_widget")
        :withUserMessage("user-facing")
        :addContext("ctx_key", "ctx_val")
        :addSuggestion("do this")
    local err = b:build()

    check("build returns error obj", error_system.is_error(err))
    check("build success is false", err.success == false)
    check("build severity", err.severity == "warning")
    check("build code", err.code == "BUILD_TEST")
    check("build message", err.message == "build me")
    check("build operation", err.operation == "my_op")
    check("build component", err.component == "my_comp")
    check("build category", err.category == "qt_widget")
    check("build user_message", err.user_message == "user-facing")
    -- build() maps context -> technical_details and suggestions -> remediation
    check("build remediation has suggestion", err.remediation[1] == "do this")
    check("build technical_details has context", err.technical_details.ctx_key == "ctx_val")
    check("build has timestamp", type(err.timestamp) == "number")
    check("build has lua_stack", type(err.lua_stack) == "string")
end

-- ============================================================
-- ErrorBuilder: automatic suggestions
-- ============================================================
print("\n--- ErrorBuilder: automatic suggestions ---")
do
    -- widget creation pattern
    local b1 = ErrorBuilder.new("error", "W", "Widget creation failed")
    local e1 = b1:build()
    local found_qt = false
    for _, s in ipairs(e1.remediation) do
        if s:find("Qt bindings") then found_qt = true end
    end
    check("auto-suggest widget creation", found_qt)

    -- layout pattern
    local b2 = ErrorBuilder.new("error", "L", "layout error occurred")
    local e2 = b2:build()
    local found_layout = false
    for _, s in ipairs(e2.remediation) do
        if s:find("parent widget") then found_layout = true end
    end
    check("auto-suggest layout", found_layout)

    -- signal pattern
    local b3 = ErrorBuilder.new("error", "S", "signal connection dropped")
    local e3 = b3:build()
    local found_signal = false
    for _, s in ipairs(e3.remediation) do
        if s:find("signal name") then found_signal = true end
    end
    check("auto-suggest signal", found_signal)

    -- nil function pattern
    local b4 = ErrorBuilder.new("error", "N", "attempt to call nil value")
    local e4 = b4:build()
    local found_module = false
    for _, s in ipairs(e4.remediation) do
        if s:find("modules are loaded") then found_module = true end
    end
    check("auto-suggest nil function", found_module)

    -- no auto-suggestions for unrelated message
    local b5 = ErrorBuilder.new("error", "X", "database timeout")
    local e5 = b5:build()
    check("no auto-suggest for unrelated", #e5.remediation == 0)
end

-- ============================================================
-- ErrorBuilder: convenience constructors
-- ============================================================
print("\n--- ErrorBuilder: convenience constructors ---")
do
    local w = ErrorBuilder.createWidgetError("widget broke")
    check("createWidgetError is builder", w.error_data ~= nil)
    check("createWidgetError category", w.error_data.category == "qt_widget")
    check("createWidgetError component", w.error_data.component == "widget_system")
    check("createWidgetError code", w.error_data.code == "WIDGET_ERROR")
    local we = w:build()
    check("createWidgetError builds", error_system.is_error(we))

    local l = ErrorBuilder.createLayoutError("layout broke")
    check("createLayoutError category", l.error_data.category == "qt_layout")
    check("createLayoutError component", l.error_data.component == "layout_system")

    local s = ErrorBuilder.createSignalError("signal broke")
    check("createSignalError category", s.error_data.category == "signals")
    check("createSignalError component", s.error_data.component == "signal_system")

    local v = ErrorBuilder.createValidationError("invalid input")
    check("createValidationError category", v.error_data.category == "validation")
    check("createValidationError component", v.error_data.component == "input_validation")
end

-- ============================================================
-- Summary
-- ============================================================
print("")
print(string.format("Passed: %d  Failed: %d  Total: %d", pass_count, fail_count, pass_count + fail_count))
if fail_count > 0 then
    print("SOME TESTS FAILED")
    os.exit(1)
else
    print("✅ test_error_system.lua passed")
end
