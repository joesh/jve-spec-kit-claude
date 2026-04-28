-- Regression: after CLOSE, operations on the closed handle must error,
-- and a freshly OPENed handle in its place must NOT be aliased by old refs.
--
-- Why: AOP and SSE used to key their internal registries on the *contained*
-- C++ object pointer (`*ud`). After CLOSE, that pointer was freed; if the
-- allocator handed the same address back on the next OPEN, the old Lua
-- userdata would silently look up the new instance — two distinct Lua
-- handles aliased to one engine. Fix: registry is keyed on Lua's stable
-- userdata allocation address (parallel to the EMP `get_map_key` pattern).
--
-- This test pins the externally-visible contract: closed handle errors on
-- use; live handles stay independent.
--
-- Run via: ./build/bin/JVEEditor --test tests/test_aop_sse_close_invalidates_handle.lua
require('test_env')

if not (qt_constants and qt_constants.AOP and qt_constants.SSE) then
    -- Qt bindings only exist inside the JVEEditor host process.
    -- Run via: ./build/bin/JVEEditor --test tests/test_aop_sse_close_invalidates_handle.lua
    print("✅ test_aop_sse_close_invalidates_handle.lua skipped (needs Qt bindings)")
    return
end

local AOP = qt_constants.AOP
local SSE = qt_constants.SSE

------------------------------------------------------------
-- AOP: closed handle must error on subsequent operations
------------------------------------------------------------
do
    local a = AOP.OPEN(48000, 2, 100)
    assert(a, "first AOP.OPEN failed")
    -- Sanity: target_buffer_ms accessor works pre-close
    assert(AOP.TARGET_BUFFER_MS(a) == 100, "first AOP target_buffer_ms")

    AOP.CLOSE(a)

    -- After CLOSE the userdata is still a valid Lua value, but every binding
    -- must reject it. Use pcall — get_aop_userdata returns nullptr → luaL_error.
    local ok, err = pcall(AOP.TARGET_BUFFER_MS, a)
    assert(not ok, "AOP.TARGET_BUFFER_MS on closed handle must error")
    assert(tostring(err):match("invalid"), "expected 'invalid' in error, got: " .. tostring(err))
end

------------------------------------------------------------
-- AOP: a fresh OPEN after a CLOSE produces an independent handle
-- (even if the allocator happens to recycle the same C++ address)
------------------------------------------------------------
do
    local a = AOP.OPEN(48000, 2, 175)
    assert(a, "AOP open A failed")
    AOP.CLOSE(a)

    local b = AOP.OPEN(48000, 2, 50)
    assert(b, "AOP open B failed")
    assert(AOP.TARGET_BUFFER_MS(b) == 50,
        "B must report its own buffer ms (not A's), got " .. AOP.TARGET_BUFFER_MS(b))

    -- A is still closed; B is alive — operations on A must still error,
    -- not silently look up B even if the allocator reused A's address.
    local ok = pcall(AOP.TARGET_BUFFER_MS, a)
    assert(not ok, "stale handle A must not alias live handle B")

    AOP.CLOSE(b)
end

------------------------------------------------------------
-- SSE: same contract for the scrub-stretch engine
------------------------------------------------------------
do
    local s = SSE.CREATE({sample_rate = 48000, channels = 2})
    assert(s, "SSE.CREATE failed")
    SSE.CLOSE(s)

    local ok, err = pcall(SSE.RESET, s)
    assert(not ok, "SSE.RESET on closed handle must error")
    assert(tostring(err):match("invalid"), "expected 'invalid' in error, got: " .. tostring(err))
end

print("✅ test_aop_sse_close_invalidates_handle.lua passed")
