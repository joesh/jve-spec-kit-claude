-- @file asserts.lua
--
-- Centralized predicate for "are asserts enabled right now?"
-- Intended usage: if asserts.enabled() then assert(...) end

local M = {}

local cached = nil

function M.enabled()
    if cached ~= nil then
        return cached
    end
    local enabled = true
    if os and os.getenv then
        enabled = os.getenv("JVE_ENABLE_ASSERTS") ~= "0"
    end
    cached = enabled
    return enabled
end

-- For tests only.
function M._set_enabled_for_tests(v)
    cached = not not v
end

return M
