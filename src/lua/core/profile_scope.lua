--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~80 LOC
-- Volatility: unknown
--
-- @file profile_scope.lua
-- Original intent (unreviewed):
-- profile_scope.lua
-- Lightweight scoped profiler helper for KRONO_TRACE instrumentation.
local krono_ok, krono = pcall(require, "core.krono")

local unpack = table.unpack or unpack

local Scope = {}
Scope.__index = Scope

local function krono_enabled()
    return krono_ok and krono and krono.is_enabled and krono.is_enabled()
end

local function now()
    if krono and krono.now then
        return krono.now()
    end
    return os.clock() * 1000
end

function Scope:new(label, opts)
    return setmetatable({
        label = label,
        opts = opts,
        start = now(),
        finished = false,
    }, Scope)
end

function Scope:finish(extra_details)
    if self.finished then
        return
    end
    self.finished = true
    local duration = now() - self.start
    local detail = extra_details
    local detail_fn = self.opts and self.opts.details_fn
    if detail_fn then
        local ok, computed = pcall(detail_fn)
        if ok and computed and computed ~= "" then
            detail = computed
        end
    end

    local logger = self.opts and self.opts.logger
    if logger then
        logger(self.label, duration, detail)
    else
        if detail then
            print(string.format("profile[%s]: %.2fms %s", self.label, duration, detail))
        else
            print(string.format("profile[%s]: %.2fms", self.label, duration))
        end
    end
end

Scope.__gc = function(self)
    -- Fallback if callers forget to finish (may run later due to GC).
    if krono_enabled() then
        self:finish()
    end
end

local dummy_scope = setmetatable({}, {
    __index = function()
        return function() end
    end
})

local M = {}

function M.begin(label, opts)
    if not krono_enabled() then
        return dummy_scope
    end
    return Scope:new(label, opts)
end

function M.wrap(label, fn, opts)
    if not krono_enabled() then
        return fn
    end
    opts = opts or {}
    return function(...)
        local scope = Scope:new(label, opts)
        local results = {pcall(fn, ...)}
        local ok = table.remove(results, 1)
        scope:finish()
        if not ok then
            error(results[1])
        end
        return unpack(results)
    end
end

return M
