-- Tests for core.cancel: request/consume/peek/clear lifecycle

require("test_env")

local cancel = require("core.cancel")
local Signals = require("core.signals")

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

print("\n=== cancel Tests ===")

-- Start clean
cancel.clear()

-- Initially not requested
check("peek: initially false", cancel.peek() == false)
check("consume: initially false", cancel.consume() == false)

-- Request sets the flag
cancel.request()
check("peek: true after request", cancel.peek() == true)

-- Consume returns true and clears
check("consume: true after request", cancel.consume() == true)
check("peek: false after consume", cancel.peek() == false)
check("consume: false after already consumed", cancel.consume() == false)

-- Clear resets without consuming
cancel.request()
check("peek: true after second request", cancel.peek() == true)
cancel.clear()
check("peek: false after clear", cancel.peek() == false)
check("consume: false after clear", cancel.consume() == false)

-- Signal emitted on request
local signal_count = 0
Signals.connect("cancel", function() signal_count = signal_count + 1 end)
cancel.request()
check("signal emitted on request", signal_count == 1)
cancel.request()
check("signal emitted again on second request", signal_count == 2)
cancel.clear()

-- Double request without consume
cancel.request()
cancel.request()
check("double request: peek still true", cancel.peek() == true)
check("double request: single consume clears", cancel.consume() == true)
check("double request: second consume false", cancel.consume() == false)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_cancel.lua passed")
