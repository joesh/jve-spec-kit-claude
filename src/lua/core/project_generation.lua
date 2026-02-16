--- Project generation counter for stale-data detection.
--
-- Increments on every project_changed signal. Modules capture the current
-- generation when they receive project-scoped data, then assert it still
-- matches before using that data. Catches bugs where a module forgets to
-- register for project_changed and retains stale state.
--
-- @file project_generation.lua

local Signals = require("core.signals")

local M = {}

local generation = 0

--- Return current project generation.
function M.current()
    return generation
end

--- Assert that a captured generation matches the current one.
-- @param captured_gen number generation captured at data-set time
-- @param caller string identifying the caller for the assert message
function M.check(captured_gen, caller)
    assert(captured_gen == generation, string.format(
        "%s: stale data from previous project (captured gen=%d, current gen=%d)",
        caller, captured_gen, generation))
end

--- Increment generation (priority 1: before all other project_changed handlers).
Signals.connect("project_changed", function()
    generation = generation + 1
end, 1)

return M
