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
-- Gap edges represent empty timeline space but are rendered at the clip boundaries they touch.
function M.to_bracket(edge_type)
    if edge_type == "gap_before" then
        return "out"
    elseif edge_type == "gap_after" then
        return "in"
    end
    return edge_type
end

return M

