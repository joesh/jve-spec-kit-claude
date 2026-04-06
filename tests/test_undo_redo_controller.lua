#!/usr/bin/env luajit

require('test_env')

local expect_error = require('test_env').expect_error
local urc = require('core.undo_redo_controller')

--------------------------------------------------------------------------------
-- Mock builder
--------------------------------------------------------------------------------

--- Build a command_manager mock with a simple linear stack.
-- @param max_pos number: how many commands are on the stack
-- @param start_pos number: starting position (0 = nothing done)
local function make_mock(max_pos, start_pos)
    local pos = start_pos or 0
    local calls = { undo = 0, redo = 0 }
    local mock = {
        can_undo = function() return pos > 0 end,
        can_redo = function() return pos < max_pos end,
        undo = function()
            calls.undo = calls.undo + 1
            pos = pos - 1
            return { success = true }
        end,
        redo = function()
            calls.redo = calls.redo + 1
            pos = pos + 1
            return { success = true }
        end,
        get_stack_state = function()
            return { current_sequence_number = pos }
        end,
    }
    return mock, calls, function() return pos end
end

--------------------------------------------------------------------------------
-- 1. handle_undo asserts on nil command_manager
--------------------------------------------------------------------------------
print("  test 1: handle_undo nil assert")
expect_error(function()
    urc.handle_undo(nil)
end, "command_manager required")

--------------------------------------------------------------------------------
-- 2. handle_redo_toggle asserts on nil command_manager
--------------------------------------------------------------------------------
print("  test 2: handle_redo_toggle nil assert")
expect_error(function()
    urc.handle_redo_toggle(nil)
end, "command_manager required")

--------------------------------------------------------------------------------
-- 3. handle_undo calls command_manager.undo()
--------------------------------------------------------------------------------
print("  test 3: handle_undo calls undo")
urc.clear_toggle()
do
    local mock, calls = make_mock(3, 2)
    urc.handle_undo(mock)
    assert(calls.undo == 1, "expected 1 undo call, got " .. calls.undo)
end

--------------------------------------------------------------------------------
-- 4. handle_undo when can_undo() returns false -> no undo call
--------------------------------------------------------------------------------
print("  test 4: handle_undo skips when can_undo=false")
urc.clear_toggle()
do
    local mock, calls = make_mock(3, 0)
    urc.handle_undo(mock)
    assert(calls.undo == 0, "expected 0 undo calls, got " .. calls.undo)
end

--------------------------------------------------------------------------------
-- 5. handle_undo clears toggle state (redo toggle interrupted by undo)
--------------------------------------------------------------------------------
print("  test 5: handle_undo clears toggle state")
urc.clear_toggle()
do
    -- Set up toggle state: redo once
    local mock, calls, get_pos = make_mock(3, 1)
    urc.handle_redo_toggle(mock)
    assert(calls.redo == 1, "setup: expected 1 redo")
    assert(get_pos() == 2, "setup: expected pos=2")

    -- Now undo (Cmd+Z) — should clear toggle
    urc.handle_undo(mock)
    assert(calls.undo == 1, "expected 1 undo call")
    assert(get_pos() == 1, "expected pos=1 after undo")

    -- Next redo_toggle should be a fresh redo, NOT a toggle-back
    urc.handle_redo_toggle(mock)
    assert(calls.redo == 2, "expected fresh redo after undo cleared toggle")
    assert(get_pos() == 2, "expected pos=2 after fresh redo")
end

--------------------------------------------------------------------------------
-- 6. handle_redo_toggle: first press does redo
--------------------------------------------------------------------------------
print("  test 6: first redo_toggle does redo")
urc.clear_toggle()
do
    local mock, calls, get_pos = make_mock(3, 1)
    urc.handle_redo_toggle(mock)
    assert(calls.redo == 1, "expected 1 redo call")
    assert(get_pos() == 2, "expected pos=2 after redo")
end

--------------------------------------------------------------------------------
-- 7. handle_redo_toggle: continues forward when more to redo
--------------------------------------------------------------------------------
print("  test 7: second redo_toggle continues forward when can_redo")
urc.clear_toggle()
do
    local mock, calls, get_pos = make_mock(3, 1)

    -- First press: redo 1→2
    urc.handle_redo_toggle(mock)
    assert(get_pos() == 2, "after 1st press: pos=2")

    -- Second press: can_redo is true (pos=2 < max=3), so redo again, not toggle
    urc.handle_redo_toggle(mock)
    assert(calls.redo == 2, "expected 2 redo calls (continued forward)")
    assert(get_pos() == 3, "after 2nd press: pos=3")
end

--------------------------------------------------------------------------------
-- 8. handle_redo_toggle: does nothing when nothing left to redo
-- (toggle-back was removed — controller is now a simple pass-through)
--------------------------------------------------------------------------------
print("  test 8: redo_toggle does nothing at end of stack")
urc.clear_toggle()
do
    -- Stack of 2 commands, start at pos=1 — only 1 redo available
    local mock, calls, get_pos = make_mock(2, 1)

    -- 1st: redo 1→2 (now at end of stack)
    urc.handle_redo_toggle(mock)
    assert(get_pos() == 2, "after 1st press: pos=2")
    assert(calls.redo == 1)

    -- 2nd: can_redo=false → early return, no undo call
    local result = urc.handle_redo_toggle(mock)
    assert(calls.undo == 0, "no undo call — toggle-back removed")
    assert(get_pos() == 2, "after 2nd press: pos=2 (unchanged)")
    assert(not result.success, "should return failure when nothing to redo")
end

--------------------------------------------------------------------------------
-- 9. handle_redo_toggle: can_redo()=false -> no redo call
--------------------------------------------------------------------------------
print("  test 9: redo_toggle skips when can_redo=false")
urc.clear_toggle()
do
    local mock, calls = make_mock(2, 2) -- at max, nothing to redo
    urc.handle_redo_toggle(mock)
    assert(calls.redo == 0, "expected 0 redo calls")
end

--------------------------------------------------------------------------------
-- 10. clear_toggle resets so next redo_toggle is fresh
--------------------------------------------------------------------------------
print("  test 10: clear_toggle resets for fresh redo")
urc.clear_toggle()
do
    local mock, calls, get_pos = make_mock(3, 1)

    -- Redo once to establish toggle state
    urc.handle_redo_toggle(mock)
    assert(get_pos() == 2)

    -- Explicitly clear
    urc.clear_toggle()

    -- Next press at pos=2 should attempt a fresh redo (2→3), not toggle-back
    urc.handle_redo_toggle(mock)
    assert(calls.redo == 2, "expected 2 total redo calls (fresh after clear)")
    assert(get_pos() == 3, "expected pos=3 after fresh redo")
end

--------------------------------------------------------------------------------
-- 11. redo failure clears toggle state
--------------------------------------------------------------------------------
print("  test 11: redo failure clears toggle")
urc.clear_toggle()
do
    local pos = 1
    local mock = {
        can_undo = function() return pos > 0 end,
        can_redo = function() return true end, -- lies about availability
        undo = function() pos = pos - 1; return { success = true } end,
        redo = function() return { success = false, error_message = "stack empty" } end,
        get_stack_state = function() return { current_sequence_number = pos } end,
    }

    local r1 = urc.handle_redo_toggle(mock)
    assert(not r1.success, "first failed redo should return success=false")
    -- Failed redo should clear toggle; next call is fresh attempt (not toggle-back)
    local undo_called = false
    mock.undo = function() undo_called = true; pos = pos - 1; return { success = true } end
    local r2 = urc.handle_redo_toggle(mock)
    assert(not r2.success, "second failed redo should also return success=false")
    assert(not undo_called, "toggle state should be cleared — undo must NOT be called on second attempt")
    assert(pos == 1, "pos should remain 1 after failed redos")
end

--------------------------------------------------------------------------------
-- 12. undo failure during toggle-back clears toggle state
--------------------------------------------------------------------------------
print("  test 12: undo failure during toggle-back clears toggle")
urc.clear_toggle()
do
    local pos = 1
    local undo_should_fail = false
    local mock = {
        can_undo = function() return pos > 0 end,
        can_redo = function() return pos < 2 end,  -- only 1 redo available
        undo = function()
            if undo_should_fail then
                return { success = false, error_message = "corruption" }
            end
            pos = pos - 1
            return { success = true }
        end,
        redo = function() pos = pos + 1; return { success = true } end,
        get_stack_state = function() return { current_sequence_number = pos } end,
    }

    -- First press: redo 1→2
    urc.handle_redo_toggle(mock)
    assert(pos == 2)

    -- Make undo fail, then toggle-back should fail and clear state
    undo_should_fail = true
    urc.handle_redo_toggle(mock)
    assert(pos == 2, "pos unchanged after failed undo")

    -- Toggle state cleared; can_redo is false at pos=2, so nothing to redo
    undo_should_fail = false
    local result = urc.handle_redo_toggle(mock)
    assert(pos == 2, "pos unchanged — nothing to redo at end of stack")
    assert(not result.success, "should report nothing to redo")
end

print("✅ test_undo_redo_controller.lua passed")
