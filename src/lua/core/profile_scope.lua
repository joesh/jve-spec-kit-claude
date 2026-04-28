--- Lightweight scoped profiler for KRONO_TRACE instrumentation.
--
-- Responsibilities:
-- - Provide a `Scope:begin(label) → :finish()` pattern that times a code span
--   and emits one line via `logger` (or a caller-provided callback) at finish.
-- - No-op transparently when `core.krono` is disabled — `begin()` returns a
--   dummy whose `:finish()` does nothing, so callers don't pay setup cost.
-- - `M.wrap(label, fn)` for the common case: time `fn`, finish under pcall,
--   re-raise on error so the timing path doesn't swallow exceptions.
--
-- Non-goals:
-- - Aggregation/statistics — emits raw spans, downstream tooling aggregates.
-- - Cross-thread span linkage — each Scope is local to the thread that
--   created it.
-- - Recovering forgotten `:finish()` calls — see invariant below.
--
-- Invariants:
-- - Every `Scope` from `M.begin()` MUST be `:finish()`ed by the same code path.
--   A missing finish is a programmer bug; we log a warning at GC instead of
--   silently completing (the GC-time duration would be meaningless and
--   masking the bug).
-- - When krono is disabled, `M.begin()` returns a sentinel whose method calls
--   are no-ops — callers can write `local s = M.begin(...); ...; s:finish()`
--   unconditionally.
--
-- @file profile_scope.lua
local krono_ok, krono = pcall(require, "core.krono")
local log = require("core.logger").for_area("ticks")

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
    elseif detail then
        log.event("profile[%s]: %.2fms %s", self.label, duration, detail)
    else
        log.event("profile[%s]: %.2fms", self.label, duration)
    end
end

Scope.__gc = function(self)
    -- Don't silently :finish() — the duration would span begin()-to-GC, which
    -- is meaningless and would mask the missing finish. Surface the bug.
    if not self.finished then
        log.warn("profile_scope: Scope '%s' was not :finish()ed (collected by GC)", self.label or "?")
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
