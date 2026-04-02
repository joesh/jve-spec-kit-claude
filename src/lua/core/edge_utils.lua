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
-- Size: ~10 LOC
-- Volatility: unknown
--
-- @file edge_utils.lua
local M = {}

-- Convert edge types to their corresponding bracket representation for rendering/display.
-- With gap-as-clip, gap clips use standard "in"/"out" edge types.
function M.to_bracket(edge_type)
    return edge_type
end

return M

